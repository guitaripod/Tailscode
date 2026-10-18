import Foundation

/// Every word the neural trace writes, in one place, so the three clients cannot say different
/// things about the same turn. Sentences are assembled from catalogue keys with arguments, never
/// from fragments glued in code, so a language may order them as it needs to.
public enum NeuralReading {
    /// What a collapsed turn says beside its glyph: the count, then the facts that qualify it.
    public struct Line: Sendable, Equatable {
        /// Calls the turn made: thoughts and notes are not tools.
        public var tools: Int
        /// "25 tools"; "7 steps" for a turn that only thought or spoke.
        public var count: String
        /// The tools by name in the order they first appeared, "Bash×18 Read×3 …".
        public var toolMix: String
        /// "8m 25s", where the turn's clock is known.
        public var duration: String?
        public var thoughts: String?
        public var notes: String?
        public var added: Int
        public var removed: Int
        /// "+5 −2", only when something was written.
        public var tally: String?
        /// "failed", or "fixed 1 error" when a later step passed what failed.
        public var failure: String?

        /// Duration, thoughts, notes and failure on one line, the way the collapsed row sets them.
        public var detail: String {
            [duration, thoughts, notes, failure].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// What a node's card says when it is pointed at.
    public struct Card: Sendable, Equatable {
        public var zone: NeuralZone
        public var title: String
        public var status: NeuralStatus
        public var statusWord: String
        /// The command, path or pattern; or the words of a thought or a note.
        public var body: String
        public var tally: String?
        public var output: [String]
        public var facts: [String]
        /// "step 6 of 29 · message 4 · 14:02:52 · same file as 3, 5".
        public var footer: String
    }

    public static let maximumMixNames = 6

    public static func isThought(_ step: NeuralStep) -> Bool {
        step.zone == .think && !step.text.isEmpty
    }

    public static func isNote(_ step: NeuralStep) -> Bool { step.zone == .say }

    public static func isTool(_ step: NeuralStep) -> Bool { !isThought(step) && !isNote(step) }

    public static func line(for turn: NeuralTurn, now: Date = Date()) -> Line {
        let census = Census(turn.steps)
        let seconds = elapsed(turn, now: now)
        return Line(
            tools: census.tools,
            count: countText(census, steps: turn.steps.count),
            toolMix: census.mixText,
            duration: seconds.map { duration($0) },
            thoughts: census.thoughts == 0
                ? nil
                : census.thoughts == 1
                    ? Localized.text("1 thought") : Localized.text("%lld thoughts", census.thoughts),
            notes: census.notes == 0
                ? nil
                : census.notes == 1
                    ? Localized.text("1 note") : Localized.text("%lld notes", census.notes),
            added: census.added, removed: census.removed, tally: tally(census.added, census.removed),
            failure: failure(unrecovered: census.failed, recovered: census.recovered))
    }

    /// The accessibility sentence for a whole turn, written from counts only.
    public static func spoken(_ turn: NeuralTurn, now: Date = Date()) -> String {
        let census = Census(turn.steps)
        var parts: [String] = []
        let count = countText(census, steps: turn.steps.count)
        if let seconds = elapsed(turn, now: now) {
            parts.append(Localized.text("%1$@ in %2$@", count, spokenDuration(seconds)))
        } else {
            parts.append(count)
        }
        for bucket in Census.Bucket.allCases {
            guard let found = census.buckets[bucket], found.calls > 0 else { continue }
            parts.append(spokenFragment(bucket, found, added: census.added, removed: census.removed))
        }
        if let ending = spokenEnding(turn.outcome) { parts.append(ending) }
        return sentences(parts)
    }

    /// The sentence a notification's long look carries: counts and what was touched, in lower
    /// case after the colon, with the lines written in brackets.
    public static func notice(for turn: NeuralTurn, now: Date = Date()) -> String {
        NeuralNoticeLine.sentence(
            NeuralNoticeCounts(Census(turn.steps), steps: turn.steps.count),
            seconds: elapsed(turn, now: now))
    }

    /// The card words for one node, from the turn's own steps: its place, its message, its time
    /// and what it shares with another step.
    public static func card(for step: NeuralStep, in steps: [NeuralStep], timeZone: TimeZone = .current) -> Card {
        let total = steps.count
        var facts: [String] = []
        let siblings = steps.filter { $0.group == step.group }.count
        if siblings > 1 {
            facts.append(Localized.text("%lld calls in one message", siblings))
        } else {
            facts.append(Localized.text("message %lld", messageNumber(of: step, in: steps)))
        }
        if let at = step.at { facts.append(clock(at, timeZone: timeZone)) }
        if let tie = tieFact(for: step, in: steps) { facts.append(tie) }
        let footer = ([Localized.text("step %1$lld of %2$lld", step.index + 1, total)] + facts)
            .joined(separator: " · ")
        let thought = isThought(step) || isNote(step)
        return Card(
            zone: step.zone, title: title(of: step), status: step.status,
            statusWord: statusWord(of: step), body: thought ? step.text : step.detail,
            tally: thought ? nil : tally(step.added ?? 0, step.removed ?? 0), output: step.outputLines,
            facts: facts, footer: footer)
    }

    /// The card for a ganglion: a zone that is full gathers its later steps in one counted node.
    public static func ganglion(zone: NeuralZone, members: [NeuralStep]) -> Card {
        let census = Census(members)
        var facts: [String] = []
        if let first = members.first, let last = members.last {
            facts.append(Localized.text("steps %1$lld to %2$lld", first.index + 1, last.index + 1))
        }
        if census.failed > 0 { facts.append(Localized.text("%lld failed", census.failed)) }
        facts.append(
            Localized.text("The zone is full, so the rest gather here. Rows lists every one."))
        return Card(
            zone: zone, title: Localized.text("%@ ganglion", zone.label),
            status: census.failed > 0 ? .failed : .ok,
            statusWord: Localized.text("%lld steps gathered here", members.count),
            body: census.mixText, tally: nil, output: [], facts: facts,
            footer: facts.joined(separator: " · "))
    }

    /// What a screen reader says on arriving at a node.
    public static func announcement(for step: NeuralStep, of total: Int) -> String {
        let base = Localized.text(
            "Step %1$lld of %2$lld, %3$@, %4$@", step.index + 1, total, title(of: step),
            statusWord(of: step))
        let said = (isThought(step) || isNote(step)) ? step.text : step.detail
        guard !said.isEmpty else { return base }
        return Localized.text("%1$@, %2$@", base, String(said.prefix(80)))
    }

    public static func title(of step: NeuralStep) -> String {
        if !step.title.isEmpty { return step.title }
        switch step.zone {
        case .think: return Localized.text("Thinking")
        case .say: return Localized.text("Said")
        default: return step.zone.label
        }
    }

    public static func statusWord(_ status: NeuralStatus) -> String {
        switch status {
        case .ok: return Localized.text("done")
        case .failed: return Localized.text("failed")
        case .running: return Localized.text("running")
        case .stopped: return Localized.text("stopped")
        case .waitingApproval, .waitingAnswer: return Localized.text("waiting for you")
        case .stalled: return Localized.text("stalled")
        }
    }

    public static var replayLabel: String { Localized.text("Replay") }
    public static var scrubLabel: String { Localized.text("Scrub through the turn") }
    public static var rowsLabel: String { Localized.text("Rows") }
    public static var stageLabel: String { Localized.text("Everything the agent did before answering") }
    public static var noNotification: String { Localized.text("No notification while it works") }

    /// "8m 25s", "42s", "1h 5m".
    public static func duration(_ seconds: TimeInterval) -> String {
        NeuralNoticeLine.duration(seconds)
    }

    /// "8 minutes 25 seconds".
    public static func spokenDuration(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        let hours = whole / 3_600
        let minutes = whole % 3_600 / 60
        let rest = whole % 60
        var parts: [String] = []
        if hours > 0 {
            parts.append(hours == 1 ? Localized.text("1 hour") : Localized.text("%lld hours", hours))
        }
        if minutes > 0 {
            parts.append(
                minutes == 1 ? Localized.text("1 minute") : Localized.text("%lld minutes", minutes))
        }
        if rest > 0 || parts.isEmpty {
            parts.append(rest == 1 ? Localized.text("1 second") : Localized.text("%lld seconds", rest))
        }
        return parts.dropFirst().reduce(parts.first ?? "") { Localized.text("%1$@ %2$@", $0, $1) }
    }

    /// A message's wall clock, "14:02:52".
    public static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    /// "+5 −2" for what a turn wrote, nil when it wrote nothing.
    public static func tally(_ added: Int, _ removed: Int) -> String? {
        NeuralNoticeLine.tally(added, removed)
    }

    /// How long the turn ran: its own start and end where known, the clock of its first and last
    /// step otherwise, and the time so far while it is still running.
    public static func elapsed(_ turn: NeuralTurn, now: Date) -> TimeInterval? {
        if let start = turn.startedAt {
            let end = turn.endedAt ?? (turn.outcome == .running ? now : nil)
            if let end, end >= start { return end.timeIntervalSince(start) }
        }
        let stamps = turn.steps.compactMap(\.at)
        guard let first = stamps.min(), let last = stamps.max(), last > first else { return nil }
        return last.timeIntervalSince(first)
    }

    static func messageNumber(of step: NeuralStep, in steps: [NeuralStep]) -> Int {
        Set(steps.map(\.group).filter { $0 <= step.group }).count
    }

    private static func tieFact(for step: NeuralStep, in steps: [NeuralStep]) -> String? {
        guard let key = step.tieKey else { return nil }
        let others = steps.filter {
            $0.id != step.id && $0.tieKey == key && $0.tieIsCommand == step.tieIsCommand
        }
        guard !others.isEmpty else { return nil }
        let numbers = others.map { String($0.index + 1) }.joined(separator: ", ")
        return step.tieIsCommand
            ? Localized.text("same command as %@", numbers)
            : Localized.text("same file as %@", numbers)
    }

    private static func countText(_ census: Census, steps: Int) -> String {
        NeuralNoticeLine.countText(tools: census.tools, steps: steps)
    }

    private static func failure(unrecovered: Int, recovered: Int) -> String? {
        if unrecovered > 0 { return Localized.text("failed") }
        if recovered == 1 { return Localized.text("fixed 1 error") }
        if recovered > 1 { return Localized.text("fixed %lld errors", recovered) }
        return nil
    }

    private static func joined(_ parts: [String]) -> String {
        parts.dropFirst().reduce(parts.first ?? "") { Localized.text("%1$@, %2$@", $0, $1) }
    }

    private static func sentences(_ parts: [String]) -> String {
        parts.map { Localized.text("%@.", $0) }.dropFirst().reduce(
            parts.first.map { Localized.text("%@.", $0) } ?? ""
        ) { Localized.text("%1$@ %2$@", $0, $1) }
    }

    private static func spokenFragment(
        _ bucket: Census.Bucket, _ found: Census.Found, added: Int, removed: Int
    ) -> String {
        let n = bucket == .edit ? found.distinct : found.calls
        var text: String
        switch bucket {
        case .shell:
            text = n == 1 ? Localized.text("Ran 1 command") : Localized.text("Ran %lld commands", n)
        case .read:
            text = n == 1 ? Localized.text("Read 1 file") : Localized.text("Read %lld files", n)
        case .search:
            text = n == 1 ? Localized.text("Searched 1 time") : Localized.text("Searched %lld times", n)
        case .edit:
            text = n == 1 ? Localized.text("Edited 1 file") : Localized.text("Edited %lld files", n)
        case .delegate:
            text = n == 1 ? Localized.text("Delegated 1 task") : Localized.text("Delegated %lld tasks", n)
        }
        var clauses: [String] = []
        if found.failed == 1 {
            clauses.append(Localized.text("one failed"))
        } else if found.failed > 1 {
            clauses.append(Localized.text("%lld failed", found.failed))
        }
        if found.recovered == 1 {
            clauses.append(Localized.text("fixed one error"))
        } else if found.recovered > 1 {
            clauses.append(Localized.text("fixed %lld errors", found.recovered))
        }
        if bucket == .edit, let lines = spokenLines(added: added, removed: removed) {
            clauses.append(lines)
        }
        return clauses.isEmpty ? text : joined([text] + clauses)
    }

    private static func spokenLines(added: Int, removed: Int) -> String? {
        let addedText = added == 1 ? Localized.text("1 line added") : Localized.text("%lld lines added", added)
        let removedText = removed == 1
            ? Localized.text("1 line removed") : Localized.text("%lld lines removed", removed)
        switch (added > 0, removed > 0) {
        case (false, false): return nil
        case (true, false): return addedText
        case (false, true): return removedText
        case (true, true): return Localized.text("%1$@ and %2$lld removed", addedText, removed)
        }
    }

    private static func spokenEnding(_ outcome: NeuralOutcome) -> String? {
        switch outcome {
        case .settled: return nil
        case .running: return Localized.text("Still working")
        case .failed: return Localized.text("It ended with an error")
        case .stopped: return Localized.text("You stopped it")
        case .interrupted: return Localized.text("The machine cut it off")
        case .answerless: return Localized.text("It ended without a word")
        }
    }

    /// The counts a turn's words are written from, taken in one pass over its steps.
    struct Census {
        enum Bucket: CaseIterable, Hashable {
            case shell, read, search, edit, delegate
        }

        struct Found {
            var calls = 0
            var failed = 0
            var recovered = 0
            var keys: Set<String> = []

            var distinct: Int { keys.isEmpty ? calls : keys.count }
        }

        var tools = 0
        var thoughts = 0
        var notes = 0
        var failed = 0
        var recovered = 0
        var added = 0
        var removed = 0
        var buckets: [Bucket: Found] = [:]
        var mix: [(name: String, count: Int)] = []

        init(_ steps: [NeuralStep]) {
            var position: [String: Int] = [:]
            for step in steps {
                if NeuralReading.isThought(step) {
                    thoughts += 1
                    continue
                }
                if NeuralReading.isNote(step) {
                    notes += 1
                    continue
                }
                tools += 1
                added += step.added ?? 0
                removed += step.removed ?? 0
                let unrecovered = step.status == .failed && !step.recovered
                let healed = step.status == .failed && step.recovered
                if unrecovered { failed += 1 }
                if healed { recovered += 1 }
                let name = step.title.isEmpty ? step.zone.label : step.title
                if let at = position[name] {
                    mix[at].count += 1
                } else {
                    position[name] = mix.count
                    mix.append((name, 1))
                }
                guard let bucket = Self.bucket(of: step) else { continue }
                var found = buckets[bucket] ?? Found()
                found.calls += 1
                if unrecovered { found.failed += 1 }
                if healed { found.recovered += 1 }
                if let key = step.tieKey ?? (step.detail.isEmpty ? nil : step.detail) {
                    found.keys.insert(key)
                }
                buckets[bucket] = found
            }
        }

        static func bucket(of step: NeuralStep) -> Bucket? {
            switch step.zone {
            case .shell: return .shell
            case .sense: return step.title.lowercased() == "read" ? .read : .search
            case .act: return .edit
            case .delegate: return .delegate
            case .think, .say: return nil
            }
        }

        var mixText: String {
            let shown = mix.prefix(NeuralReading.maximumMixNames).map {
                $0.count > 1 ? "\($0.name)\u{00D7}\($0.count)" : $0.name
            }
            let text = shown.joined(separator: " ")
            return mix.count > NeuralReading.maximumMixNames ? text + " \u{2026}" : text
        }
    }
}
