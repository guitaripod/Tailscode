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

    /// True when the level that will go out is not the one that was asked for.
    public var moved: Bool { asked != nil && level != asked }

    /// The sentence for a toast, or nil when nothing moved.
    public func notice(modelName: String) -> String? {
        guard moved, let asked else { return nil }
        let was = Self.word(asked)
        guard takesLevels else {
            return Localized.text("%1$@ dropped. %2$@ takes no effort level.", was, modelName)
        }
        guard let level else {
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
    /// The nearest level at or under what was asked for, among the levels a model takes.
    public static func carry(_ level: String?, options: [String]) -> EffortCarry {
        let takes = isOffered(options: options)
        guard let level, !level.isEmpty else {
            return EffortCarry(level: nil, asked: nil, takesLevels: takes)
        }
        if options.contains(level) {
            return EffortCarry(level: level, asked: level, takesLevels: true)
        }
        guard takes, let ceiling = heat(of: level) else {
            return EffortCarry(level: nil, asked: level, takesLevels: takes)
        }
        let cooler = ModelDial.ascending(options: options)
            .filter { !ModelDial.isPower($0) }
            .compactMap { candidate in ModelDial.rank(candidate).map { (candidate, $0) } }
            .filter { $0.1 <= ceiling }
        guard let best = cooler.max(by: { $0.1 < $1.1 }) else {
            return EffortCarry(level: nil, asked: level, takesLevels: true)
        }
        return EffortCarry(level: best.0, asked: level, takesLevels: true)
    }

    /// What effort becomes after a model pick, with the account of it: the same rule as `adopt`,
    /// for a surface that wants to say what happened.
    public static func adoption(
        _ level: String?, for selection: ModelSelection?, models: [ModelInfo], agentOptions: [String]
    ) -> EffortCarry {
        carry(level, options: options(models: models, selection: selection, agentOptions: agentOptions))
    }

    private static func heat(of level: String) -> Int? {
        ModelDial.isPower(level) ? EffortMeter.bars + 1 : ModelDial.rank(level)
    }
}
