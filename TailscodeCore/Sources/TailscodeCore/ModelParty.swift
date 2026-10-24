import CodingAgentKit
import Foundation

/// One of the six places a person keeps a model: the model at a level, taken as one decision, and a
/// name if they gave it one.
public struct PartySlot: Sendable, Hashable {
    public var preset: ModelPreset
    public var name: String?

    public init(preset: ModelPreset, name: String? = nil) {
        self.preset = preset
        self.name = name
    }
}

public enum PartyPlacement: Sendable, Equatable {
    case placed(Int)
    case full
}

/// The six models a person carries, on this device.
///
/// Six, always: the grid shows six places filled or hollow so its shape never moves under a thumb,
/// and order is the person's — slot one is ⌃⌥1, and a swipe along the pill walks the filled ones as
/// a ring. The first time the party is read it is filled from what was already pinned, in order,
/// so nothing is asked of anyone and nothing is taken away: pins and stars keep their own lists,
/// which are the box.
public enum ModelParty {
    public static let size = 6
    public static let nameLimit = 24
    static let storageKey = "tailscode.modelParty"
    public static let didChange = Notification.Name("tailscode.modelParty.didChange")

    private struct Entry: Codable {
        let model: String
        let effort: String
        let name: String?
    }

    public static func slots() -> [PartySlot?] {
        guard let raw = UserDefaults.standard.string(forKey: storageKey) else {
            let seeded = seed()
            write(seeded)
            return seeded
        }
        let entries =
            raw.data(using: .utf8).flatMap { try? JSONDecoder().decode([Entry?].self, from: $0) }
            ?? []
        let slots = (0..<size).map { index -> PartySlot? in
            guard index < entries.count, let entry = entries[index],
                let selection = ModelSelection(string: entry.model),
                let effort = PresetEffort(raw: entry.effort)
            else { return nil }
            return PartySlot(preset: ModelPreset(selection: selection, effort: effort), name: entry.name)
        }
        return slots
    }

    public static func slot(_ index: Int) -> PartySlot? {
        let all = slots()
        return all.indices.contains(index) ? all[index] : nil
    }

    /// The filled slots' presets, in slot order.
    public static func presets() -> [ModelPreset] {
        slots().compactMap { $0?.preset }
    }

    /// What a swipe along the pill and a step walk: the party, and while the party is empty the
    /// pins, exactly as before there was one.
    public static func ring() -> [ModelPreset] {
        let party = presets()
        return party.isEmpty ? ModelPresetStore.all() : party
    }

    /// The slot a chat running `model` at `effort` is in, if it is in one.
    public static func index(of model: ModelSelection?, effort: String?) -> Int? {
        slots().firstIndex { $0?.preset.matches(model: model, effort: effort) ?? false }
    }

    /// Puts a model in the first hollow slot. The same model at the same level is never placed
    /// twice; and with six full nothing moves, so the surface can ask which one makes room.
    @discardableResult
    public static func place(_ preset: ModelPreset, name: String? = nil) -> PartyPlacement {
        var all = slots()
        if let existing = all.firstIndex(where: { $0?.preset == preset }) { return .placed(existing) }
        guard let hollow = all.firstIndex(where: { $0 == nil }) else { return .full }
        all[hollow] = PartySlot(preset: preset, name: normalized(name))
        write(all)
        return .placed(hollow)
    }

    public static func replace(slot: Int, with preset: ModelPreset, name: String? = nil) {
        var all = slots()
        guard all.indices.contains(slot) else { return }
        all[slot] = PartySlot(preset: preset, name: normalized(name))
        write(all)
    }

    public static func release(slot: Int) {
        var all = slots()
        guard all.indices.contains(slot), all[slot] != nil else { return }
        all[slot] = nil
        write(all)
    }

    public static func rename(slot: Int, to name: String?) {
        var all = slots()
        guard all.indices.contains(slot), var held = all[slot] else { return }
        held.name = normalized(name)
        all[slot] = held
        write(all)
    }

    public static func setEffort(slot: Int, _ effort: PresetEffort) {
        var all = slots()
        guard all.indices.contains(slot), var held = all[slot] else { return }
        held.preset = ModelPreset(selection: held.preset.selection, effort: effort)
        all[slot] = held
        write(all)
    }

    /// Two balls change places; a ball dropped on a hollow slot simply moves there.
    public static func swap(_ first: Int, _ second: Int) {
        var all = slots()
        guard all.indices.contains(first), all.indices.contains(second), first != second else {
            return
        }
        all.swapAt(first, second)
        write(all)
    }

    /// A name as it is kept: trimmed, one space between words, at most ``nameLimit`` characters,
    /// and nothing when nothing is left — which hands the card back to the model's own word.
    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let words = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let joined = words.joined(separator: " ")
        guard !joined.isEmpty else { return nil }
        return String(joined.prefix(nameLimit)).trimmingCharacters(in: .whitespaces)
    }

    private static func seed() -> [PartySlot?] {
        let pins = ModelPresetStore.all().prefix(size).map { PartySlot(preset: $0) }
        return (0..<size).map { $0 < pins.count ? pins[$0] : nil }
    }

    private static func write(_ slots: [PartySlot?]) {
        let entries = slots.map { slot in
            slot.map {
                Entry(
                    model: $0.preset.selection.rawValue, effort: $0.preset.effort.raw,
                    name: $0.name)
            }
        }
        guard let data = try? JSONEncoder().encode(entries),
            let raw = String(data: data, encoding: .utf8)
        else { return }
        guard UserDefaults.standard.string(forKey: storageKey) != raw else { return }
        UserDefaults.standard.set(raw, forKey: storageKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
