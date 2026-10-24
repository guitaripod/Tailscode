import CodingAgentKit
import Foundation

/// What a pick of a model on another machine does with the conversation it was made from: the
/// brief it carries and, for a retry, the question it puts back in the field. Decided here so the
/// three clients cannot disagree about what moves.
public struct CarryPlan: Sendable, Equatable {
    public let brief: ConversationBrief?
    public let draft: String?

    public init(brief: ConversationBrief?, draft: String? = nil) {
        self.brief = brief
        self.draft = draft
    }

    public static let nothing = CarryPlan(brief: nil)

    /// The whole conversation, for a pick made from the model chooser.
    public static func continuing(
        pick: ModelPick, title: String, messages: [ChatMessage]
    ) -> CarryPlan {
        CarryPlan(
            brief: ConversationBrief.make(
                title: title, messages: messages, window: window(for: pick)))
    }

    /// Everything before the question an answer was given to, and the question as the draft.
    public static func branching(
        pick: ModelPick, title: String, messages: [ChatMessage], answerID: String
    ) -> CarryPlan {
        guard let question = ConversationBrief.question(before: answerID, in: messages),
            let draft = ConversationBrief.typed(question)
        else { return .nothing }
        return CarryPlan(
            brief: ConversationBrief.make(
                title: title, messages: messages, before: question.id, window: window(for: pick)),
            draft: draft)
    }

    /// The window of the model the brief is going to, from what that machine last told us.
    public static func window(for pick: ModelPick) -> Int? {
        window(of: pick.selection, in: ModelCatalogStore.cached(pick.profileID))
    }

    public static func window(of selection: ModelSelection?, in models: [ModelInfo]) -> Int? {
        guard let selection else { return nil }
        let exact = models.first {
            $0.id == selection.modelID && $0.providerID == selection.providerID
        }
        return (exact ?? models.first { $0.id == selection.modelID })?.contextWindow
    }

    /// The alert a pick of another machine earns: carrying words when there is something to carry,
    /// today's words when there is not.
    public func moveWords(for pick: ModelPick) -> (title: String, body: String, action: String) {
        brief == nil
            ? (ModelFleet.moveTitle(pick), ModelFleet.moveBody(pick), ModelFleet.moveAction)
            : (ModelFleet.carryTitle(pick), ModelFleet.carryBody(pick), ModelFleet.carryAction)
    }
}
