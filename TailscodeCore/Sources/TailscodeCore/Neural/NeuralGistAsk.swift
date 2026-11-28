import Foundation

/// What a model is asked so that it tells a turn in short, and how its answer is read. The log it
/// is given is the turn's own account: the notes the agent wrote, whole enough to carry their
/// meaning, and each run of work between two notes as the one line the account already says for
/// it. Reasoning, tool output and pictures are never sent, what looks like a secret is taken out,
/// and the instruction is fixed, so a person can read exactly what is asked.
///
/// The answer is checked rather than trusted: a stage ends where an item of the account ends, the
/// stages rise and the last one ends at the last step read, more stages than a surface has rows
/// for are folded into their heavier neighbours, and anything that cannot be read that way is no
/// answer at all.
public struct NeuralGistAsk: Sendable, Equatable {
    /// The longest log sent, in characters. A model on a laptop holds a few thousand tokens.
    public static let logBudget = 14_000
    static let noteLimits = [280, 180, 110, 70]
    static let titleLimit = 64
    static let nowLimit = 150
    static let stageLimit = 60

    public let system: String
    public let user: String
    public let stepCount: Int
    public let running: Bool
    /// The step numbers an item of the account ends at, rising: where a stage may end.
    public let ends: [Int]

    public static func system(stages: ClosedRange<Int>, language: String?) -> String {
        var text = """
            You turn the log of one working session of a coding agent into a short story a person reads at a glance.
            Answer with JSON only, in exactly this shape:
            {"title": "...", "now": "...", "stages": [{"says": "...", "to": 0}]}
            title: what the whole session is for, 3 to 7 words, no period.
            now: one plain sentence of at most 14 words. If the session is still running, what is happening at the end of the log, in the present tense. If it finished, what it came to, in the past tense.
            stages: the session in order, \(stages.lowerBound) to \(stages.upperBound) stages of roughly similar weight that together cover every step. "to" is the number of the last step of the stage, and the last stage's "to" is the last step in the log. "says" is 3 to 7 words and at most 44 characters, starting with a verb in the past tense and never naming the agent. If the session is still running, the last stage is in progress and starts with a verb ending in -ing.
            If stages told earlier are listed, keep a told stage's words and last step where it still fits, and merge early told stages as the story grows.
            Say what was achieved in plain words, never file names, commands, flags or code. Use only what the log says. Never invent a result.
            Example: {"title": "Fixing the login crash", "now": "Running the tests after the fix.", "stages": [{"says": "Found where the crash starts", "to": 14}, {"says": "Fixed the empty-name case", "to": 31}, {"says": "Running the tests again", "to": 38}]}
            """
        if let language, !language.isEmpty, language.lowercased() != "english" {
            text += "\nWrite the title, now and says in \(language)."
        }
        return text
    }

    /// The ask for a turn's account as it stands. Nil for a turn too short to be worth telling
    /// or one with nothing in it a model could read.
    public static func make(
        account: NeuralAccount, stepCount: Int, running: Bool, prompt: String?, answer: String?,
        told: NeuralGist?, language: String? = NeuralGistAsk.appLanguage
    ) -> NeuralGistAsk? {
        guard NeuralGistPolicy.worthTelling(stepCount: stepCount) else { return nil }
        var ends: [Int] = []
        for item in account.items {
            if let end = lastNumber(of: item), end <= stepCount, end > (ends.last ?? 0) { ends.append(end) }
        }
        guard !ends.isEmpty else { return nil }
        if ends.last != stepCount { ends.append(stepCount) }
        var lines: [String] = []
        for limit in noteLimits {
            lines = log(account.items, stepCount: stepCount, noteLimit: limit)
            if lines.reduce(0, { $0 + $1.count + 1 }) <= logBudget { break }
        }
        lines = trimmed(lines)
        guard !lines.isEmpty else { return nil }
        let bounds = NeuralGistPolicy.stageBounds(stepCount: stepCount)
        var user = ""
        if let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            user += "What the person asked: " + oneLine(PlainModel.redact(prompt, limit: 400)) + "\n"
        }
        user += running ? "The session is still running.\n" : "The session is finished.\n"
        let heavy = heavyStages(of: told, stepCount: stepCount, most: bounds.upperBound)
        if !heavy.isEmpty {
            user += "Stages told earlier:\n"
            for stage in heavy { user += "- steps \(stage.from)-\(stage.to): \(stage.says)\n" }
        }
        user += "Log (\(stepCount) steps):\n" + lines.joined(separator: "\n")
        if !running, let answer = answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty {
            user += "\nWhat it answered at the end: " + oneLine(PlainModel.redact(answer, limit: 600))
        }
        return NeuralGistAsk(
            system: system(stages: bounds, language: language), user: user, stepCount: stepCount,
            running: running, ends: ends)
    }

    /// The JSON body of the chat completion. A model that can think first is asked not to, and
    /// one that can be held to JSON is.
    public func body(model: String) -> Data {
        let body: [String: Any] = [
            "model": model, "stream": false, "temperature": 0.2, "max_tokens": 600,
            "chat_template_kwargs": ["enable_thinking": false],
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// What was written, read out of a chat completion's body. Nil when it is not a telling.
    public func read(
        completion data: Data, writer: String, place: String, at date: Date = Date()
    ) -> NeuralGist? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = object["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else { return nil }
        return read(content, writer: writer, place: place, at: date)
    }

    /// What was written, read out of the model's own words: the first JSON object in them, with
    /// thinking and a code fence around it passed over.
    public func read(_ text: String, writer: String, place: String, at date: Date = Date()) -> NeuralGist? {
        let plain = ImageGenBrief.stripThinking(text)
        guard let open = plain.firstIndex(of: "{"), let close = plain.lastIndex(of: "}"), open < close,
            let object = try? JSONSerialization.jsonObject(with: Data(plain[open...close].utf8))
                as? [String: Any]
        else { return nil }
        let title = Self.clean(object["title"] as? String, limit: Self.titleLimit, period: false)
        let now = Self.clean(object["now"] as? String, limit: Self.nowLimit, period: true)
        let listed = (object["stages"] ?? object["chapters"]) as? [[String: Any]] ?? []
        var stages: [NeuralGist.Stage] = []
        var previous = 0
        for entry in listed {
            let says = Self.clean(entry["says"] as? String, limit: Self.stageLimit, period: false)
            guard !says.isEmpty, let raw = (entry["to"] as? NSNumber)?.intValue else { continue }
            let end = snap(raw)
            guard end > previous else { continue }
            stages.append(NeuralGist.Stage(says: says, from: previous + 1, to: end))
            previous = end
        }
        guard !title.isEmpty, !now.isEmpty, let last = stages.last else { return nil }
        if last.to != stepCount {
            stages[stages.count - 1] = NeuralGist.Stage(says: last.says, from: last.from, to: stepCount)
        }
        return NeuralGist(
            title: title, now: now, stages: Self.folded(stages, keepLast: running), stepCount: stepCount,
            running: running, writer: writer, place: place, writtenAt: date)
    }

    /// The end of the account item a step falls in, so a stage never cuts a run of work in two.
    func snap(_ number: Int) -> Int {
        let bounded = min(max(number, 1), stepCount)
        return ends.first { $0 >= bounded } ?? stepCount
    }

    /// More stages than a surface has rows for, folded: the lightest neighbouring pair becomes one
    /// stage under the heavier one's words, until they fit. A running turn's last stage keeps its
    /// own words, since it is the one that says what is happening.
    static func folded(
        _ stages: [NeuralGist.Stage], keepLast: Bool, most: Int = NeuralGistPolicy.mostStages
    ) -> [NeuralGist.Stage] {
        var held = stages
        while held.count > max(most, 1) {
            var best = 0
            var lightest = Int.max
            for index in 0..<(held.count - 1) {
                let weight = held[index].stepCount + held[index + 1].stepCount
                if weight < lightest {
                    lightest = weight
                    best = index
                }
            }
            let first = held[best]
            let second = held[best + 1]
            let lastPair = best + 1 == held.count - 1
            let says = (keepLast && lastPair) || second.stepCount > first.stepCount ? second.says : first.says
            held.replaceSubrange(best...(best + 1), with: [NeuralGist.Stage(says: says, from: first.from, to: second.to)])
        }
        return held
    }

    /// The told stages worth showing the model again: the ones that carry a fair share of the
    /// turn. A light early stage is left out, so the model tells that part again and it merges
    /// into its neighbours as the story grows.
    static func heavyStages(of told: NeuralGist?, stepCount: Int, most: Int) -> [NeuralGist.Stage] {
        guard let told, told.stages.count > 1 else { return [] }
        let floor = Double(stepCount) / Double(2 * max(most, 1))
        return told.stages.dropLast().filter { Double($0.stepCount) >= floor }
    }

    static func lastNumber(of item: NeuralAccount.Item) -> Int? {
        switch item {
        case .said(let said): return said.number
        case .thought(let thought): return thought.number
        case .work(let work): return work.numbers.last
        case .ask(let ask): return ask.number
        case .answer: return nil
        }
    }

    static func log(_ items: [NeuralAccount.Item], stepCount: Int, noteLimit: Int) -> [String] {
        var lines: [String] = []
        for item in items {
            switch item {
            case .said(let said) where said.number <= stepCount:
                lines.append("\(said.number). SAID: " + oneLine(PlainModel.redact(said.text, limit: noteLimit)))
            case .work(let work):
                guard let first = work.numbers.first, let last = work.numbers.last, first <= stepCount else { continue }
                let range = first == last ? "\(first)" : "\(first)-\(min(last, stepCount))"
                let clauses = work.clauses(limit: 6)
                var words = clauses.shown.map(\.text).joined(separator: ", ")
                if words.isEmpty { words = work.words }
                if work.unfixedCount > 0 { words += " (\(work.unfixedCount) failed)" }
                lines.append("\(range). WORK: " + oneLine(PlainModel.redact(words, limit: 240)))
            case .ask(let ask) where ask.number <= stepCount:
                lines.append("\(ask.number). WAITING: " + oneLine(ask.sentence))
            default:
                continue
            }
        }
        return lines
    }

    /// A log still over the budget with its notes at their shortest keeps its first third and its
    /// newest lines, and says how much was left out between them.
    static func trimmed(_ lines: [String]) -> [String] {
        let total = lines.reduce(0) { $0 + $1.count + 1 }
        guard total > logBudget else { return lines }
        var head: [String] = []
        var used = 0
        for line in lines {
            guard used + line.count + 1 <= logBudget / 3 else { break }
            head.append(line)
            used += line.count + 1
        }
        var tail: [String] = []
        for line in lines.dropFirst(head.count).reversed() {
            guard used + line.count + 1 <= logBudget else { break }
            tail.append(line)
            used += line.count + 1
        }
        let left = lines.count - head.count - tail.count
        return head + (left > 0 ? ["(\(left) lines of the log are left out here)"] : []) + tail.reversed()
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// A sentence as a surface shows it: one line, no quotes or code marks around it, never
    /// naming the agent, no period on a title, and cut at a word when it runs long.
    static func clean(_ raw: String?, limit: Int, period: Bool) -> String {
        guard let raw else { return "" }
        var text = oneLine(raw).replacingOccurrences(of: "`", with: "")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D} "))
        for lead in ["The agent is ", "The agent has ", "The agent ", "Agent "] where text.hasPrefix(lead) {
            text = String(text.dropFirst(lead.count))
            break
        }
        if !period {
            while text.hasSuffix(".") { text.removeLast() }
        }
        if let first = text.first, first.isLowercase {
            text = first.uppercased() + text.dropFirst()
        }
        guard text.count > limit else { return text }
        var cut = String(text.prefix(limit))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            cut = String(cut[..<space])
        }
        return cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:")) + "\u{2026}"
    }

    /// The language the app speaks, by its English name, which is what a model is told to write in.
    public static var appLanguage: String? {
        guard let code = Bundle.main.preferredLocalizations.first?.split(separator: "-").first else { return nil }
        return Locale(identifier: "en").localizedString(forLanguageCode: String(code))
    }
}
