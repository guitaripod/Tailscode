import CodingAgentKit
import Foundation

/// A turn the machine was pulled out from under, read into words a person can act on.
///
/// This is the one failure that looks exactly like success. The prompt is in the transcript, no
/// answer follows it, the spinner is gone, and nothing anywhere says an answer was ever coming —
/// so the conversation reads as a question that was ignored rather than as work that was cut in
/// half. The agent may have been three files into an edit when the power went.
///
/// Everything here is read off what the server actually recorded. How far the work got comes from
/// the agent's own transcript rather than from anything it claimed about itself, and the card
/// never says what caused the stop, because nobody knows: a bridge that was updated, a machine
/// that slept and a process that was killed all leave the same evidence.
public struct InterruptedTurn: Sendable, Hashable {
    /// What was asked, as the person wrote it.
    public let prompt: String
    public let title: String
    /// One sentence: what happened, and when it was noticed.
    public let detail: String
    /// What the turn had already done, one line each, in the order a person triages in. Empty when
    /// the turn was cut off before it did anything, which is a fact worth its own line.
    public let progress: [String]
    /// Prompts that were waiting behind the interrupted turn and never ran.
    public let queued: [String]
    /// The whole thing as one sentence, for a screen reader.
    public let spoken: String
    /// Whether the work has already been picked back up — the card stays, saying so, until the
    /// resumed turn produces something, because a card that vanishes on the press leaves a person
    /// with no idea whether it worked.
    public let isResumed: Bool

    public var resumeTitle: String { Localized.text("Pick it back up") }
    public var dismissTitle: String { Localized.text("Let it go") }

    /// The face, in the same two alphabets every state in this app is drawn in. A cut-off turn is
    /// settled — nothing is running — so it holds perfectly still, and it wears the attention tone
    /// rather than the danger one: nothing failed, something stopped.
    public static let symbol = "bolt.horizontal.circle"
    public static let glyph = "⚡"
    public static let tone = ActivityTone.attention
}

public enum InterruptedTurnReading {
    /// Reads what the server reported into the card, or `nil` when there is nothing to say.
    public static func read(_ cutOff: TurnInterruption?, now: Date = Date()) -> InterruptedTurn? {
        guard let cutOff else { return nil }
        let ran = span(from: cutOff.startedAt, to: cutOff.detectedAt)
        let ago = elapsed(from: cutOff.detectedAt, to: now)
        let title =
            cutOff.resumedAt != nil
            ? Localized.text("Picking the turn back up")
            : Localized.text("The server stopped mid-answer")
        let detail =
            cutOff.resumedAt != nil
            ? Localized.text(
                "The work is being continued from where it stopped. Everything above is still this same conversation.")
            : Localized.text(
                "This turn had been running %@ when the machine running it stopped. It was noticed %@, when the server came back — nothing was wrong with what you asked.",
                ran, ago)
        let lines = progressLines(cutOff.progress)
        let card = InterruptedTurn(
            prompt: cutOff.prompt,
            title: title,
            detail: detail,
            progress: lines,
            queued: cutOff.queued,
            spoken: spoken(title: title, detail: detail, progress: lines, queued: cutOff.queued),
            isResumed: cutOff.resumedAt != nil)
        return card
    }

    /// What the turn had actually done. Counted rather than characterised: a client shows the
    /// account, and the person decides whether continuing or starting over is the safer move.
    static func progressLines(_ progress: TurnInterruption.Progress) -> [String] {
        guard !progress.isEmpty else {
            return [Localized.text("It had not done anything yet — nothing on the machine changed.")]
        }
        var lines: [String] = []
        if progress.toolCount > 0 {
            lines.append(
                progress.toolCount == 1
                    ? Localized.text("Ran 1 tool")
                    : Localized.text("Ran %@ tools", "\(progress.toolCount)"))
        }
        if let last = progress.lastTool, !last.isEmpty {
            lines.append(Localized.text("Was in the middle of %@", last))
        }
        if !progress.filesTouched.isEmpty {
            lines.append(
                Localized.text(
                    "Wrote to %@", list(progress.filesTouched.map { name(of: $0) })))
        }
        if !progress.commands.isEmpty {
            lines.append(Localized.text("Ran %@", list(progress.commands)))
        }
        if let partial = progress.partialAnswer, !partial.isEmpty {
            lines.append(Localized.text("Had started answering: “%@”", partial))
        }
        return lines
    }

    private static func spoken(
        title: String, detail: String, progress: [String], queued: [String]
    ) -> String {
        var parts = [title, detail]
        parts.append(contentsOf: progress)
        if !queued.isEmpty {
            parts.append(
                queued.count == 1
                    ? Localized.text("One prompt was waiting behind it and never ran.")
                    : Localized.text(
                        "%@ prompts were waiting behind it and never ran.", "\(queued.count)"))
        }
        return parts.joined(separator: " ")
    }

    /// At most three, named, with the rest counted — a list that runs off the card tells nobody
    /// anything.
    static func list(_ items: [String], limit: Int = 3) -> String {
        let shown = items.prefix(limit).joined(separator: ", ")
        guard items.count > limit else { return shown }
        return Localized.text("%@ and %@ more", shown, "\(items.count - limit)")
    }

    static func name(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// How long the turn ran before it was cut off.
    static func span(from: Date, to: Date) -> String {
        duration(max(0, to.timeIntervalSince(from)))
    }

    /// How long ago something was noticed, in the same words.
    static func elapsed(from: Date, to: Date) -> String {
        let seconds = max(0, to.timeIntervalSince(from))
        guard seconds >= 60 else { return Localized.text("just now") }
        return Localized.text("%@ ago", duration(seconds))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return Localized.text("%@s", "\(Int(seconds.rounded()))")
        }
        if seconds < 3_600 {
            return Localized.text("%@m", "\(Int((seconds / 60).rounded()))")
        }
        let hours = seconds / 3_600
        return hours < 10
            ? Localized.text("%@h", String(format: "%.1f", hours))
            : Localized.text("%@h", "\(Int(hours.rounded()))")
    }
}

/// The rules, checked headlessly so all three clients are proved against one set of answers.
public enum InterruptedTurnCheck {
    public static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }

        expect(InterruptedTurnReading.read(nil) == nil, "nothing interrupted says nothing")

        let started = Date(timeIntervalSince1970: 1_000_000)
        let detected = started.addingTimeInterval(340)
        let now = detected.addingTimeInterval(120)
        let busy = TurnInterruption(
            turnID: "t1", prompt: "port the toggles", startedAt: started, detectedAt: detected,
            progress: TurnInterruption.Progress(
                toolCount: 7, lastTool: "Edit", filesTouched: ["/a/b/Theme.swift", "/a/b/Row.swift"],
                commands: ["swift build"], partialAnswer: "I have started by"),
            queued: ["and then the mac"])
        guard let card = InterruptedTurnReading.read(busy, now: now) else {
            failures.append("an interrupted turn reads as a card")
            return failures
        }
        expect(card.prompt == "port the toggles", "the card carries what was asked")
        expect(!card.isResumed, "and knows it has not been picked up")
        expect(card.detail.contains("6m"), "it says how long the turn had been running")
        expect(card.detail.contains("2m ago"), "and when it was noticed")
        expect(card.progress.contains { $0.contains("7") }, "the tools are counted")
        expect(
            card.progress.contains { $0.contains("Theme.swift") && !$0.contains("/a/b") },
            "files are named, not pathed")
        expect(card.queued == ["and then the mac"], "and what never ran is kept")
        expect(card.spoken.contains("One prompt was waiting"), "read out whole")

        let untouched = TurnInterruption(
            turnID: "t2", prompt: "hello", startedAt: started, detectedAt: detected)
        expect(
            InterruptedTurnReading.read(untouched, now: now)?.progress.first?.contains("nothing")
                == true,
            "a turn that did nothing says so rather than listing nothing")

        let resumed = TurnInterruption(
            turnID: "t3", prompt: "hello", startedAt: started, detectedAt: detected,
            resumedAt: now)
        expect(
            InterruptedTurnReading.read(resumed, now: now)?.isResumed == true,
            "a resumed turn still shows, saying so")

        expect(
            InterruptedTurnReading.list(["a", "b", "c", "d"]).contains("1 more"),
            "a long list counts its tail")
        expect(InterruptedTurnReading.duration(45).contains("45"), "seconds under a minute")
        expect(InterruptedTurnReading.duration(3_600 * 3).contains("3.0"), "hours past an hour")
        expect(
            InterruptedTurnReading.elapsed(from: started, to: started) == Localized.text("just now"),
            "no time at all is just now")
        return failures
    }
}
