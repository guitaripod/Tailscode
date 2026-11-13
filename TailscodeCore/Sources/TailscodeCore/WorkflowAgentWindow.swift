import Foundation

/// The agents a workflow card draws as rows: all of them while the run is small, and past that a
/// fixed handful, so a card costs the same whether its script fanned out to eight agents or to six
/// hundred.
///
/// A card built one row per agent laid six hundred and sixty stacked rows into one transcript cell,
/// and the phone's layout engine spent longer solving them than the system watchdog waits before it
/// kills the app. The window keeps the agents a reader is looking at a run for — any they have open,
/// then the ones still out, then the ones that reported last — and draws them in the run's own
/// order, so a row does not jump past its neighbours the moment it finishes. Everything else is a
/// count the card folds into one line, which opens the whole roster somewhere built to hold a list
/// that long.
public struct WorkflowAgentWindow: Sendable, Hashable {
    /// How many agent rows a card draws before it folds the rest.
    public static let rowLimit = 8

    public let shown: [WorkflowAgent]
    public let folded: Int

    /// - Parameters:
    ///   - keeping: agents the reader has open in the card. An open row that rotated out of the
    ///     window as newer agents reported would vanish from under the transcript being read.
    ///   - limit: the most rows the card draws. A fold line that would hide a single agent takes
    ///     the same room as that agent's own row, so a run one over the limit shows whole.
    public init(
        _ run: WorkflowRun, keeping: Set<String> = [], limit: Int = WorkflowAgentWindow.rowLimit
    ) {
        let agents = run.agents
        let limit = max(1, limit)
        guard agents.count > limit + 1 else {
            shown = agents
            folded = 0
            return
        }
        var chosen = Set<Int>()
        if !keeping.isEmpty {
            for index in agents.indices.reversed() where chosen.count < limit {
                if keeping.contains(agents[index].id) { chosen.insert(index) }
            }
        }
        for index in agents.indices.reversed() where chosen.count < limit {
            if !chosen.contains(index),
                ActivityIcon.workflowAgent(agents[index], in: run) == .openWork
            {
                chosen.insert(index)
            }
        }
        for index in agents.indices.reversed() where chosen.count < limit {
            chosen.insert(index)
        }
        shown = chosen.sorted().map { agents[$0] }
        folded = agents.count - shown.count
    }

    /// The words on the fold line, or nothing when the card draws every agent.
    public var foldedLabel: String? {
        folded > 0 ? Localized.text("+%lld more", folded) : nil
    }

    /// Every agent in the run as one line each — its mark, what it was asked, and how long it was
    /// out — for the reader a fold line opens. It is plain lines rather than rows, because the
    /// reason the card folded them is that six hundred of anything drawn as rows is the hang.
    public static func roster(of run: WorkflowRun, at now: Date) -> String {
        run.agents.map { agent in
            let icon = ActivityIcon.workflowAgent(agent, in: run)
            let title = agent.title.replacingOccurrences(of: "\n", with: " ")
            guard let elapsed = agent.elapsed(at: now, in: run) else {
                return "\(icon.glyph)  \(title)"
            }
            return "\(icon.glyph)  \(title)  ·  \(WorkflowRun.duration(elapsed))"
        }
        .joined(separator: "\n")
    }
}
