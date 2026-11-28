import Foundation

/// A turn in short with no model to tell it: the same title, sentence and stages a telling has,
/// made from the turn's own words. A stage begins where the agent said something and is named by
/// what it said there, the title is what was asked, and the sentence is how the answer opens (or
/// the newest note of a turn still running). Nothing is written by anyone but the person and the
/// agent, so it wears no model's mark, costs no request and is the same on every machine; a
/// telling a model writes takes its place when one arrives.
public enum NeuralGistOutline {
    /// The longest a stage's name, the title and the sentence run.
    public static let stageLimit = 44
    public static let titleLimit = 56
    public static let sentenceLimit = 140

    /// The outline of a turn as its account stands, or nil for a turn too short to need one or
    /// one in which the agent said nothing twice, which has no stages to name.
    public static func make(
        account: NeuralAccount, stepCount: Int, running: Bool, prompt: String?, answer: String?, at now: Date
    ) -> NeuralGist? {
        guard NeuralGistPolicy.worthTelling(stepCount: stepCount) else { return nil }
        var stages: [NeuralGist.Stage] = []
        var from = 1
        var says: String?
        var newest: String?
        for item in account.items {
            guard case .said(let said) = item, said.number <= stepCount else { continue }
            let words = lead(of: said.text, limit: stageLimit, period: false)
            guard !words.isEmpty else { continue }
            if let held = says, said.number > from {
                stages.append(NeuralGist.Stage(says: held, from: from, to: said.number - 1))
                from = said.number
            }
            says = words
            newest = said.text
        }
        guard let last = says else { return nil }
        stages.append(NeuralGist.Stage(says: last, from: from, to: stepCount))
        let most = NeuralGistPolicy.stageBounds(stepCount: stepCount).upperBound
        stages = NeuralGistAsk.folded(stages, keepLast: running, most: most)
        guard stages.count > 1 else { return nil }
        let sentence = running
            ? lead(of: newest, limit: sentenceLimit, period: true)
            : lead(of: answer, limit: sentenceLimit, period: true)
        return NeuralGist(
            title: lead(of: prompt, limit: titleLimit, period: false),
            now: sentence.isEmpty ? NeuralGistWords.result(of: account) : sentence, stages: stages,
            stepCount: stepCount, running: running, writer: "", place: "", writtenAt: now)
    }

    /// How a passage opens: its first sentence on one line, cut at a word.
    static func lead(of text: String?, limit: Int, period: Bool) -> String {
        guard let text, let line = text.split(whereSeparator: \.isNewline).first(where: { !bare($0).isEmpty }) else {
            return ""
        }
        var sentence = bare(line)
        let ends = [". ", "! ", "? "].compactMap { sentence.range(of: $0)?.upperBound }
        if let first = ends.min() { sentence = String(sentence[..<first]).trimmingCharacters(in: .whitespaces) }
        return NeuralGistAsk.clean(sentence, limit: limit, period: period)
    }

    /// A line without the marks a note is written with: a heading's hashes, a list's bullet,
    /// emphasis stars.
    private static func bare(_ line: Substring) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        while let first = text.first, "#>-*\u{2022}".contains(first) { text.removeFirst() }
        return text.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
    }
}
