import AppIntents
import CodingAgentKit
import Foundation
import TailscodeCore

/// One of the six places a person keeps a model, as Siri, Spotlight and the Shortcuts app know
/// it: the name they gave it or the model's own word, with the model, its level and the server
/// that runs it beneath, so a spoken "use Sprint" and a tap in the Action Button's picker mean the
/// same slot.
struct PartySlotEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Party Slot")
    static let defaultQuery = PartySlotQuery()

    let id: Int
    let title: String
    let detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(detail)")
    }
}

struct PartySlotQuery: EntityQuery {
    func entities(for identifiers: [Int]) async throws -> [PartySlotEntity] {
        await Self.filled().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [PartySlotEntity] {
        await Self.filled()
    }

    @MainActor
    static func filled() -> [PartySlotEntity] {
        let sources = ModelFleet.sources(
            profiles: ConnectionController.shared.profiles, current: nil)
        return PartyReading.cards(
            slots: ModelParty.slots(), sources: sources, model: nil, effort: nil, agentOptions: []
        )
        .filter { !$0.isHollow }
        .map { card in
            let place = card.server.map { String(localized: "on \($0)") }
            return PartySlotEntity(
                id: card.chord, title: card.title,
                detail: [card.subtitle, place].compactMap { $0 }.joined(separator: " · "))
        }
    }
}

/// Take a slot of the party from outside the app: Siri ("Use Sprint in Tailscode"), a Shortcut,
/// Spotlight or the Action Button. The chat in front moves onto the slot's model and level, and
/// with none in front the box on Home is aimed at it. Which slot travels as its number, in
/// process (`PendingRoute.deliver(partySlot:)`), never as a link anything else on the phone could
/// open.
struct UsePartySlotIntent: AppIntent {
    static let title: LocalizedStringResource = "Use a Model"
    static let description = IntentDescription(
        "Switch to one of the six models you carry. Tailscode opens on it.")
    static let openAppWhenRun = true

    @Parameter(title: "Slot")
    var slot: PartySlotEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Use \(\.$slot)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingRoute.deliver(partySlot: slot.id)
        return .result()
    }
}
