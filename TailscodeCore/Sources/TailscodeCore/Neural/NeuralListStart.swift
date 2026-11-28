import Foundation

/// What the step list of a Megatron starts on when a person opens it: only what the agent said,
/// which is the outline of a turn, or every step. Said is the start because a list of three
/// hundred commands is the work and forty notes are the account of it; the choice a person makes
/// on the SAID chip is the start from then on, so someone who wants every step is asked once.
public enum NeuralListStart {
    public enum Choice: String, Sendable {
        case said
        case everything
    }

    public static let key = "tailscode.neural.listStart"

    /// A check or a bench sets this so every run starts the same, whatever the machine holds.
    nonisolated(unsafe) public static var override: Choice?

    public static var current: Choice {
        override ?? UserDefaults.standard.string(forKey: key).flatMap(Choice.init(rawValue:)) ?? .said
    }

    /// The person pressed a zone chip and the list is now this: said alone is the start again,
    /// no zone at all is every step, and any other filter is a look, not a preference.
    static func note(_ filter: NeuralStepList.Filter) {
        guard override == nil, !filter.failedOnly, filter.query.isEmpty else { return }
        let choice: Choice
        if filter.zones == [.say] { choice = .said } else if filter.zones.isEmpty { choice = .everything } else { return }
        guard choice != current else { return }
        UserDefaults.standard.set(choice.rawValue, forKey: key)
    }
}

extension NeuralStepList {
    /// The list shows what the agent said and nothing else.
    public var isSaidOnly: Bool { filter.zones == [.say] && !filter.failedOnly && filter.query.isEmpty }

    /// The list is narrowed by something a person set for this look: any filter that is not the
    /// start itself. A surface that warns of a filter warns of this.
    public var isNarrowed: Bool {
        guard filter.isChosen else { return false }
        return !(isSaidOnly && NeuralListStart.current == .said)
    }
}

extension NeuralBrainModel {
    /// A person opened this turn's Megatron: its list takes the start, once for the turn, and
    /// only where the agent said something and nothing is filtering yet. Answers with the effects
    /// a client draws, as `browse` does.
    @discardableResult
    public mutating func startList() -> [NeuralBrowse.Effect] {
        guard !browseState.started else { return [] }
        browseState.started = true
        guard NeuralListStart.current == .said, !browseState.list.isFiltered,
            browseState.list.zoneChips.contains(where: { $0.zone == .say && $0.count > 0 }),
            browseState.list.zoneChips.contains(where: { $0.zone != .say && $0.count > 0 })
        else { return [] }
        var state = browseState
        state.list.cursor = pinnedStep
        let (next, effects) = NeuralBrowse.reduce(state: state, action: .zoneChip(.say, solo: true))
        browseState = next
        refreshSelection()
        return effects
    }

    /// The first step of a run that the list is showing, one-based and inclusive: where the
    /// cursor goes when a stage opens, so a filter is never cleared to put it there.
    public func firstVisibleStep(in numbers: ClosedRange<Int>) -> String? {
        for number in numbers where number >= 1 && number <= steps.count {
            let id = steps[number - 1].id
            if browseState.list.isVisible(id) { return id }
        }
        return nil
    }
}
