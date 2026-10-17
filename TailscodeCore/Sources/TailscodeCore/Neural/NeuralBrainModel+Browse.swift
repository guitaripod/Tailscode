import Foundation

extension NeuralBrainModel {
    /// Does what a key or a pointer event asks of the step list and returns the effects the
    /// client draws. The list's cursor is this model's pin: it is set from the pin before the
    /// reducer runs and written back to it after, so the head's ring, the leader and the readout
    /// follow the list. A hover is a preview: it rings its node and leaves the cursor alone.
    @discardableResult
    public mutating func browse(_ action: NeuralBrowse.Action) -> [NeuralBrowse.Effect] {
        var state = browseState
        state.list.cursor = pinnedStep
        let (next, effects) = NeuralBrowse.reduce(state: state, action: action)
        browseState = next
        applyCursor(next.cursor)
        hovered = next.hovered.flatMap { indexByID[$0] == nil ? nil : layout.representative(of: $0) }
        refreshSelection()
        return effects
    }

    /// The effects the model itself raised since the client last asked, such as scrolling a list
    /// that follows a running turn to its newest step.
    public mutating func drainBrowseEffects() -> [NeuralBrowse.Effect] {
        defer { pendingBrowseEffects = [] }
        return pendingBrowseEffects
    }

    /// The account effects the reducer raised (go to the ask, reply with a quote) since the client
    /// last asked.
    public mutating func drainAccountEffects() -> [NeuralBrowse.AccountEffect] {
        defer { browseState.outbox = [] }
        return browseState.outbox
    }

    /// The step list as it stands.
    public var stepList: NeuralStepList { browseState.list }

    /// The step the readout previews: the hovered row, or the cursor when the hover ends.
    public var previewedStep: String? { browseState.hovered ?? pinnedStep }

    mutating func applyCursor(_ id: String?) {
        guard id != pinnedStep else { return }
        guard let id, indexByID[id] != nil else {
            pinned = nil
            pinnedMember = nil
            return
        }
        let node = layout.representative(of: id)
        pinned = node
        pinnedMember = id == node ? nil : id
    }

    mutating func syncGanglia() {
        browseState.list.setGanglia(Dictionary(uniqueKeysWithValues: layout.ganglia.map { ($0.leader, $0.members) }))
    }

    mutating func refreshBrowse(previousCount: Int) {
        let live = turn.outcome == .running
        browseState.list.update(steps: turn.steps, live: live)
        syncGanglia()
        browseState.list.cursor = pinnedStep
        if let id = browseState.hovered, indexByID[id] == nil { browseState.hovered = nil }
        if live, turn.steps.count > previousCount {
            let (next, effects) = NeuralBrowse.reduce(state: browseState, action: .liveStepArrived)
            browseState = next
            pendingBrowseEffects += effects
        }
    }
}
