import TailscodeCore
import UIKit

/// One thing the account says, as the account draws it: the person's prompt, the agent's own plan,
/// its notes, its thoughts, a run of work folded to a line, and what came of the turn. Built from
/// Core's `NeuralAccount` and narrowed to what the step list's filters show, so SAID solo makes the
/// account the transcript of what the agent told you.
struct BrainAccountItem: Identifiable {
    struct Cluster {
        let zone: NeuralZone
        let count: Int
        let failed: Int
    }

    struct Clause {
        let text: String
        let verdict: NeuralVerdict.Step
        let stepIDs: [String]
    }

    struct Work {
        let stepIDs: [String]
        let numbers: [Int]
        let clusters: [Cluster]
        let clauses: [Clause]
        let fixedWords: [String]
        let failureCount: Int
        let firstFailedStepID: String?
        let isFiltered: Bool

        var first: Int { numbers.first ?? 0 }
        var last: Int { numbers.last ?? 0 }
    }

    enum Kind {
        case asked(NeuralAccount.Asked)
        case plan(NeuralAccount.Plan)
        case said(NeuralAccount.Said)
        case thought(NeuralAccount.Thought)
        case work(Work)
        case result(NeuralAccount.Result)
    }

    let id: String
    let kind: Kind

    var reuseID: String {
        switch kind {
        case .asked: return "asked"
        case .plan: return "plan"
        case .said: return "said"
        case .thought: return "thought"
        case .work: return "work"
        case .result: return "result"
        }
    }

    /// The steps the item stands for: what its chips set the cursor to.
    var stepIDs: [String] {
        switch kind {
        case .said(let said): return [said.stepID]
        case .thought(let thought): return [thought.stepID]
        case .work(let work): return work.stepIDs
        case .plan(let plan): return [plan.stepID]
        case .asked, .result: return []
        }
    }

    var isSaid: Bool {
        if case .said = kind { return true }
        return false
    }

    var isWork: Bool {
        if case .work = kind { return true }
        return false
    }
}

enum BrainAccountItems {
    static let askedID = "asked"
    static let planID = "plan"
    static let resultID = "result"

    /// The items of `account` the list's filters leave. The ask and the live step are not among
    /// them: they are pinned above the story.
    static func make(
        model: NeuralBrainModel, account: NeuralAccount, list: NeuralStepList
    ) -> [BrainAccountItem] {
        let filtered = list.isFiltered
        var out: [BrainAccountItem] = []
        if !filtered, let asked = account.asked {
            out.append(BrainAccountItem(id: askedID, kind: .asked(asked)))
        }
        if !filtered, let plan = account.plan {
            out.append(BrainAccountItem(id: planID, kind: .plan(plan)))
        }
        for item in account.story {
            switch item {
            case .said(let said):
                if !filtered || list.isVisible(said.stepID) {
                    out.append(BrainAccountItem(id: said.id, kind: .said(said)))
                }
            case .thought(let thought):
                if !filtered || list.isVisible(thought.stepID) {
                    out.append(BrainAccountItem(id: thought.id, kind: .thought(thought)))
                }
            case .work(let work):
                if let made = makeWork(work, list: list, filtered: filtered) { out.append(made) }
            case .answer, .ask:
                break
            }
        }
        if !filtered, let result = account.result, !result.isEmpty {
            out.append(BrainAccountItem(id: resultID, kind: .result(result)))
        }
        return out
    }

    private static func makeWork(
        _ work: NeuralAccount.Work, list: NeuralStepList, filtered: Bool
    ) -> BrainAccountItem? {
        guard filtered else {
            return BrainAccountItem(
                id: work.id,
                kind: .work(
                    BrainAccountItem.Work(
                        stepIDs: work.stepIDs, numbers: work.numbers,
                        clusters: work.clusters.map {
                            BrainAccountItem.Cluster(zone: $0.zone, count: $0.count, failed: $0.failed)
                        },
                        clauses: work.clauseList.map {
                            BrainAccountItem.Clause(text: $0.text, verdict: $0.verdict, stepIDs: $0.stepIDs)
                        }, fixedWords: work.fixedWords,
                        failureCount: work.unfixedCount, firstFailedStepID: work.firstFailedStepID,
                        isFiltered: false)))
        }
        let ids = work.stepIDs.filter { list.isVisible($0) }
        guard !ids.isEmpty else { return nil }
        let rows = ids.compactMap { list.row(id: $0) }
        var clusters: [BrainAccountItem.Cluster] = []
        var clauses: [BrainAccountItem.Clause] = []
        var failed = 0
        for row in rows {
            if row.verdict == .failed { failed += 1 }
            if let last = clusters.last, last.zone == row.zone {
                clusters[clusters.count - 1] = BrainAccountItem.Cluster(
                    zone: last.zone, count: last.count + 1,
                    failed: last.failed + (row.isFailure ? 1 : 0))
            } else {
                clusters.append(
                    BrainAccountItem.Cluster(zone: row.zone, count: 1, failed: row.isFailure ? 1 : 0))
            }
            if let last = clauses.last, last.text == row.title {
                clauses[clauses.count - 1] = BrainAccountItem.Clause(
                    text: last.text, verdict: last.verdict, stepIDs: last.stepIDs + [row.id])
            } else {
                clauses.append(
                    BrainAccountItem.Clause(text: row.title, verdict: row.verdict, stepIDs: [row.id]))
            }
        }
        return BrainAccountItem(
            id: work.id,
            kind: .work(
                BrainAccountItem.Work(
                    stepIDs: ids, numbers: rows.map(\.number), clusters: clusters, clauses: clauses,
                    fixedWords: [], failureCount: failed,
                    firstFailedStepID: rows.first { $0.isFailure }?.id, isFiltered: true)))
    }
}
