import CodingAgentKit
import Foundation

/// What a level becomes when the model under it changes.
///
/// A level somebody asked for is not thrown away because the next model has no word for it: it
/// moves to the nearest cooler rung that model does take, and says so. Never hotter — a level is
/// a spend, and a model that has no `max` must not quietly send `ultracode` — and never silently:
/// the move is a fact the person is told, because a chip that changed its word on its own reads as
/// a control that does not work.
public struct EffortCarry: Sendable, Equatable {
    /// What the next send will carry. Nil is the server deciding.
    public let level: String?
    /// What was asked for before the model changed. Nil when nothing was.
    public let asked: String?
    /// Whether the model takes any level at all.
    public let takesLevels: Bool

    public init(level: String?, asked: String?, takesLevels: Bool) {
        self.level = level
        self.asked = asked
        self.takesLevels = takesLevels
    }

    /// True when the level that will go out is not the one that was asked for. A spelling that
    /// differs only in case is the same level, and no move.
    public var moved: Bool {
        guard let asked else { return false }
        guard let level else { return true }
        return !EffortVocabulary.same(level, asked)
    }

    /// The sentence for a toast, or nil when nothing moved. "No cooler level" is said only of a
    /// word whose place on the scale is known; a word nobody can place is said to be missing,
    /// which is all that is true of it.
    public func notice(modelName: String) -> String? {
        guard moved, let asked else { return nil }
        let was = Self.word(asked)
        guard takesLevels else {
            return Localized.text("%1$@ dropped. %2$@ takes no effort level.", was, modelName)
        }
        guard let level else {
            guard EffortVocabulary.reach(asked) != nil else {
                return Localized.text("%1$@ handed back to the server. %2$@ has no %1$@.", was, modelName)
            }
            return Localized.text("%1$@ handed back to the server. %2$@ has no cooler level.", was, modelName)
        }
        return Localized.text("%1$@ moved to %2$@. %3$@ has no %1$@.", was, Self.word(level), modelName)
    }

    /// The same fact before it has happened, for a preview that says what taking a row would do.
    public func forecast(modelName: String) -> String? {
        guard moved, let asked else { return nil }
        let was = Self.word(asked)
        guard takesLevels else { return Localized.text("%@ takes no effort level.", modelName) }
        guard let level else { return Localized.text("%@ will go back to the server.", was) }
        return Localized.text("%1$@ will carry over as %2$@.", was, Self.word(level))
    }

    private static func word(_ level: String) -> String {
        ModelDial.isPower(level) ? Ultracode.menuTitle.lowercased() : level
    }
}

extension ModelEffort {
    /// The nearest level at or under what was asked for, among the levels a model takes, in the
    /// model's own spelling. Places are compared on one scale (`EffortVocabulary.reach`), so a
    /// local model's think finds Claude's medium and Claude's high finds think; a level the table
    /// has not met on the model's side is placed by the bars it lights, so what the ladder shows is
    /// never hotter than what was asked. A word nobody can place on the asking side — a budget, a
    /// private name, the model deciding — goes back to the server.
    public static func carry(_ level: String?, options: [String]) -> EffortCarry {
        let takes = isOffered(options: options)
        guard let level, !EffortVocabulary.key(level).isEmpty else {
            return EffortCarry(level: nil, asked: nil, takesLevels: takes)
        }
        if let own = EffortVocabulary.spelling(of: level, in: options) {
            return EffortCarry(level: own, asked: level, takesLevels: true)
        }
        guard takes, let ceiling = EffortVocabulary.reach(level) else {
            return EffortCarry(level: nil, asked: level, takesLevels: takes)
        }
        let placements = ModelDial.placements(options: options)
        let cooler = ModelDial.ascending(options: options)
            .filter { !ModelDial.isPower($0) && !EffortVocabulary.isAutomatic($0) }
            .compactMap { candidate -> (level: String, reach: Double)? in
                let reach = EffortVocabulary.reach(candidate)
                    ?? placements[EffortVocabulary.key(candidate)].map(Double.init)
                return reach.map { (candidate, $0) }
            }
            .filter { $0.reach <= ceiling }
        guard let best = cooler.max(by: { $0.reach < $1.reach }) else {
            return EffortCarry(level: nil, asked: level, takesLevels: true)
        }
        return EffortCarry(level: best.level, asked: level, takesLevels: true)
    }

    /// What effort becomes after a model pick, with the account of it: the same rule as `adopt`,
    /// for a surface that wants to say what happened.
    public static func adoption(
        _ level: String?, for selection: ModelSelection?, models: [ModelInfo], agentOptions: [String]
    ) -> EffortCarry {
        carry(level, options: options(models: models, selection: selection, agentOptions: agentOptions))
    }
}
