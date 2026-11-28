import Foundation

/// The telling the demo world carries. No model answers there, so the scripted film turn comes
/// with the words a model wrote for it once, set against the turn as it stands: three stages by
/// their share of its steps, each ending where an item of the account ends.
public enum NeuralGistDemo {
    public static var writer: String { YourModelWords.title }
    /// The note the scripted film turn writes first, which is how the turn is known.
    public static let filmNote = "Building it from the existing film rig."

    public static func isFilm(_ model: NeuralBrainModel) -> Bool {
        model.steps.contains { $0.text == filmNote }
    }

    /// Sets the film turn's telling for a surface that is showing it, where no model of the
    /// person's own would write one, and sets it again when the turn has moved on.
    public static func placeIfNeeded(key: String, model: NeuralBrainModel, desk: NeuralGistDesk = .shared) {
        guard !desk.isMuted, desk.writer == nil, isFilm(model) else { return }
        let held = desk.reading(for: key).gist
        let running = model.turn.outcome == .running
        guard held == nil || held?.running != running || held?.stepCount != model.steps.count,
            let gist = film(for: model)
        else { return }
        desk.place(gist, for: key, model: model)
    }

    private static let stages: [(says: String, share: Double)] = [
        (Localized.text("Looked over the film rig"), 0.22),
        (Localized.text("Mapped the song and built the release"), 0.68),
        (Localized.text("Cut the footage to the beat"), 1),
    ]

    /// The film turn in short, or nil for a turn too short to tell.
    public static func film(for model: NeuralBrainModel) -> NeuralGist? {
        let count = model.steps.count
        let running = model.turn.outcome == .running
        guard NeuralGistPolicy.worthTelling(stepCount: count),
            let ask = NeuralGistAsk.make(
                account: model.account(), stepCount: count, running: running, prompt: nil, answer: nil, told: nil)
        else { return nil }
        var told: [NeuralGist.Stage] = []
        var previous = 0
        for (index, stage) in stages.enumerated() {
            let wanted = index == stages.count - 1 ? count : Int((Double(count) * stage.share).rounded())
            let end = index == stages.count - 1 ? count : ask.snap(max(wanted, previous + 1))
            guard end > previous else { continue }
            told.append(NeuralGist.Stage(says: stage.says, from: previous + 1, to: end))
            previous = end
        }
        guard let last = told.last, last.to == count else { return nil }
        return NeuralGist(
            title: Localized.text("Making the product demo film"),
            now: running
                ? Localized.text("Cutting the footage so the first tap lands on the riff.")
                : Localized.text("The film is rendered and its first tap lands on the riff."),
            stages: told, stepCount: count, running: running, writer: writer, place: "",
            writtenAt: Date(timeIntervalSince1970: 0))
    }
}

/// The sample the Your model page shows for a telling: the scripted film turn, what the rules say
/// of it, and what the person's own model writes for it when asked.
public enum NeuralGistSample {
    static func model() -> NeuralBrainModel? {
        NeuralTurns.partition(messages: NeuralDemo.turn(), running: false).last.map { NeuralBrainModel(turn: $0) }
    }

    /// The film turn as the rules say it: "Ran 18 commands, read 3 files, edited 2 files."
    public static var rulesWords: String {
        guard let model = model() else { return "" }
        let clauses = model.brainCard(now: Date(timeIntervalSince1970: 0)).digestClauses
        return clauses.isEmpty ? "" : clauses.joined(separator: ", ") + "."
    }

    /// Asks the model for the film turn in short, once, whatever the switch says: the person
    /// pressed Show me. Nil when it did not answer with a telling.
    public static func write(
        helper: ImageGenHelper, transport: any NeuralGistTransport = NeuralGistURLTransport()
    ) async -> NeuralGist? {
        guard YourModelStore.isPrivate(helper), let model = model(),
            let ask = NeuralGistAsk.make(
                account: model.account(), stepCount: model.steps.count, running: false,
                prompt: "Make a product demonstration .mp4", answer: nil, told: nil),
            let url = URL(string: helper.address + "/v1/chat/completions"),
            let data = try? await transport.post(url, body: ask.body(model: helper.model))
        else { return nil }
        return ask.read(
            completion: data, writer: helper.label ?? helper.model,
            place: YourModelWords.inSentence(YourModelWords.machine(of: helper)))
    }

    /// The telling on one line, wearing the mark: its title, then its sentence.
    public static func line(_ gist: NeuralGist) -> String {
        "\(NeuralGistWords.mark) \(gist.title). \(gist.now)"
    }

    public static var failed: String { Localized.text("It did not answer with a telling just now.") }
}
