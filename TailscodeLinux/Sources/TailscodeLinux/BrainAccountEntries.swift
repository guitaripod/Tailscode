import Foundation
import TailscodeCore

/// One thing the account says, as the account draws it: the question that began the turn, the
/// agent's plan when it has finished, its notes, its thoughts, a run of work folded to a line, and
/// the result that closes the story. Built from Core's `NeuralAccount` and narrowed to what the
/// step list's filters show, so SAID solo makes the account the transcript of what the agent told
/// you. Adding a kind is a case here, a builder in `BrainAccountCells` and a line in the key.
struct AccountEntry: Identifiable {
    /// One clause of a work line as the account draws it: Core's clause, or one made for the
    /// steps a filter leaves.
    struct Clause: Equatable {
        let text: String
        let verdict: NeuralVerdict.Step
        let stepIDs: [String]

        init(text: String, verdict: NeuralVerdict.Step, stepIDs: [String]) {
            self.text = text
            self.verdict = verdict
            self.stepIDs = stepIDs
        }

        init(_ clause: NeuralAccount.Clause) {
            self.init(text: clause.text, verdict: clause.verdict, stepIDs: clause.stepIDs)
        }
    }

    /// What a work line says about the steps it folds: the zones it touched, one mark each, and
    /// the clauses in the reader's words with how each one went.
    struct Work {
        let stepIDs: [String]
        let numbers: [Int]
        let zones: [NeuralZone]
        let clauses: [Clause]
        let more: Int
        /// The amber words for each error that was fixed: "fixed an error at step 8".
        let fixedWords: [String]
        let fixedCount: Int
        let unfixedCount: Int
        let file: NeuralAccount.Change?
        let fileCount: Int
        let added: Int
        let removed: Int
        /// The step a press on the work's chip goes to: the first that stayed failed, else the
        /// first that was fixed, else the first.
        let chipStepID: String?

        var firstStepID: String? { stepIDs.first }
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

    /// The steps the entry stands for: what its chips set the cursor to.
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

    var isResult: Bool {
        if case .result = kind { return true }
        return false
    }

    /// An entry the story walks over: the notes, the thoughts and the work, not its frame.
    var isStory: Bool {
        switch kind {
        case .said, .thought, .work: return true
        case .asked, .plan, .result: return false
        }
    }
}

enum AccountEntries {
    /// The entries of `account` that the list's filters leave: every one when nothing is filtered.
    /// The ask is not among them: it is pinned above the story, and so are the Now line and a
    /// running turn's plan.
    static func make(model: NeuralBrainModel, account: NeuralAccount, list: NeuralStepList) -> [AccountEntry] {
        let filtered = list.isFiltered
        var out: [AccountEntry] = []
        if !filtered, let asked = account.asked { out.append(AccountEntry(id: asked.id, kind: .asked(asked))) }
        if !filtered, !account.header.isRunning, let plan = account.plan {
            out.append(AccountEntry(id: "plan:" + plan.stepID, kind: .plan(plan)))
        }
        for item in account.story {
            switch item {
            case .said(let said):
                if !filtered || list.isVisible(said.stepID) { out.append(AccountEntry(id: said.id, kind: .said(said))) }
            case .thought(let thought):
                if !filtered || list.isVisible(thought.stepID) {
                    out.append(AccountEntry(id: thought.id, kind: .thought(thought)))
                }
            case .work(let work):
                if let entry = makeWork(work, model: model, list: list, filtered: filtered) { out.append(entry) }
            case .answer(let answer):
                guard showsResult(list.filter), let result = account.result,
                    !result.isEmpty || result.changedWords != nil || result.answerWords != nil
                else { break }
                out.append(AccountEntry(id: answer.id, kind: .result(result)))
            case .ask:
                break
            }
        }
        if out.last?.isResult != true, !filtered, let result = account.result, answerlessResult(result, account: account) {
            out.append(AccountEntry(id: "result:" + account.header.speaker, kind: .result(result)))
        }
        return out
    }

    /// A settled turn with no final text still has a result worth saying: what it changed, ran,
    /// and that it ended without an answer.
    private static func answerlessResult(_ result: NeuralAccount.Result, account: NeuralAccount) -> Bool {
        account.answer == nil && (!result.isEmpty || result.answerWords != nil)
    }

    /// The result closes the story unless the filters ask for something it is not part of.
    static func showsResult(_ filter: NeuralStepList.Filter) -> Bool {
        (filter.zones.isEmpty || filter.zones.contains(.say)) && !filter.failedOnly && filter.query.isEmpty
    }

    private static func makeWork(
        _ work: NeuralAccount.Work, model: NeuralBrainModel, list: NeuralStepList, filtered: Bool
    ) -> AccountEntry? {
        let ids = work.stepIDs.filter { !filtered || list.isVisible($0) }
        guard !ids.isEmpty else { return nil }
        let whole = ids.count == work.stepIDs.count
        let steps = ids.compactMap { model.step(id: $0) }
        var order: [NeuralZone] = []
        for step in steps where !order.contains(step.zone) { order.append(step.zone) }
        let visible = Set(ids)
        let changes = work.changes.filter { visible.contains($0.stepID) }
        let rows = ids.compactMap { list.row(id: $0) }
        let clauses: [AccountEntry.Clause]
        let more: Int
        let fixedWords: [String]
        let fixed: Int
        let unfixed: Int
        if whole {
            let shown = work.clauses(limit: 4)
            clauses = shown.shown.map(AccountEntry.Clause.init)
            more = shown.more
            fixedWords = work.fixedWords
            fixed = work.fixedCount
            unfixed = work.unfixedCount
        } else {
            let made = localClauses(rows)
            clauses = Array(made.prefix(4))
            more = max(0, made.count - 4)
            let fixedRows = rows.filter { $0.verdict == .fixed }
            fixedWords = fixedRows.map { NeuralReading.fixedAtStep($0.number) }
            fixed = fixedRows.count
            unfixed = rows.filter { $0.verdict == .failed }.count
        }
        let chip = rows.first { $0.verdict == .failed }?.id ?? rows.first { $0.verdict == .fixed }?.id ?? ids.first
        return AccountEntry(
            id: work.id,
            kind: .work(
                AccountEntry.Work(
                    stepIDs: ids, numbers: steps.map { $0.index + 1 }, zones: order, clauses: clauses,
                    more: more, fixedWords: fixedWords, fixedCount: fixed, unfixedCount: unfixed,
                    file: changes.first, fileCount: changes.count,
                    added: changes.reduce(0) { $0 + $1.added }, removed: changes.reduce(0) { $0 + $1.removed },
                    chipStepID: chip)))
    }

    /// Clauses for the steps a filter leaves of a work line: a run of one sentence is one clause,
    /// "Pushed (2x)", with the most pressing verdict among its steps.
    private static func localClauses(_ rows: [NeuralStepList.Row]) -> [AccountEntry.Clause] {
        var out: [AccountEntry.Clause] = []
        var counts: [Int] = []
        for row in rows {
            if let last = out.last, last.text.hasPrefix(row.title) || last.text == row.title,
                let previous = rows.first(where: { $0.id == last.stepIDs.last }), previous.title == row.title
            {
                let count = counts[counts.count - 1] + 1
                counts[counts.count - 1] = count
                out[out.count - 1] = AccountEntry.Clause(
                    text: Localized.text("%1$@ (%2$lldx)", row.title, count),
                    verdict: worse(last.verdict, row.verdict), stepIDs: last.stepIDs + [row.id])
            } else {
                out.append(AccountEntry.Clause(text: row.title, verdict: row.verdict, stepIDs: [row.id]))
                counts.append(1)
            }
        }
        return out
    }

    private static func worse(_ a: NeuralVerdict.Step, _ b: NeuralVerdict.Step) -> NeuralVerdict.Step {
        func rank(_ v: NeuralVerdict.Step) -> Int {
            switch v {
            case .failed: return 7
            case .waiting: return 6
            case .stalled: return 5
            case .tryingAgain: return 4
            case .running: return 3
            case .stopped: return 2
            case .fixed: return 1
            case .done: return 0
            }
        }
        return rank(b) > rank(a) ? b : a
    }
}
