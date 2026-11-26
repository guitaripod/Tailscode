import CodingAgentKit
import Foundation

/// A line the server wrote for the reader, as every client draws it: one sentence, the symbol and
/// glyph beside it, and the tone it wears.
///
/// A note sits between the turns rather than inside one (the model changing hands, a turn picked
/// back up after a restart, work the agent left running coming back), so it is drawn as a quiet
/// line across the transcript, never as a message somebody sent. It holds still: a note is a fact
/// about what already happened.
public struct TranscriptNoteLine: Sendable, Hashable {
    public let text: String
    public let symbol: String
    public let glyph: String
    public let tone: ActivityTone
    /// The same line for a screen reader, which needs to be told it is a note.
    public let spoken: String
}

public enum TranscriptNoteReading {
    /// Reads a note into its line. `modelName` turns a model into the name a person picked it by,
    /// where the client has the catalog; without one the model's own id stands in.
    public static func read(
        _ note: TranscriptNote, modelName: (ModelSelection) -> String? = { _ in nil }
    ) -> TranscriptNoteLine {
        let text = sentence(note.subject, modelName: modelName)
        let face = face(note.subject)
        return TranscriptNoteLine(
            text: text, symbol: face.symbol, glyph: face.glyph, tone: face.tone,
            spoken: Localized.text("Note: %@", text))
    }

    /// The note a message is, when it is one.
    public static func note(in message: ChatMessage) -> TranscriptNote? {
        for part in message.parts {
            if case .note(let note) = part.kind { return note }
        }
        return nil
    }

    private static func sentence(
        _ subject: TranscriptNote.Subject, modelName: (ModelSelection) -> String?
    ) -> String {
        switch subject {
        case .model(let model, let effort, let previous):
            let name = modelName(model) ?? model.modelID
            let now = effort.map { Localized.text("%1$@ at %2$@ effort", name, $0) } ?? name
            guard let previous else { return Localized.text("Switched to %@", now) }
            return Localized.text(
                "Switched from %1$@ to %2$@", modelName(previous) ?? previous.modelID, now)
        case .agent(let agent, let previous):
            guard let previous else { return Localized.text("Switched to the %@ agent", agent) }
            return Localized.text("Switched from the %1$@ agent to %2$@", previous, agent)
        case .resumedAfterRestart:
            return Localized.text("The server restarted and picked this turn back up")
        case .workFinished(let title, let work, let outcome):
            let name = oneLine(title)
            switch (work, outcome) {
            case (.command, .completed): return Localized.text("Background command finished: %@", name)
            case (.command, .cancelled): return Localized.text("Background command cancelled: %@", name)
            case (.command, .failed): return Localized.text("Background command failed: %@", name)
            case (.agent, .completed): return Localized.text("Background agent finished: %@", name)
            case (.agent, .cancelled): return Localized.text("Background agent cancelled: %@", name)
            case (.agent, .failed): return Localized.text("Background agent failed: %@", name)
            }
        case .instructions(let words), .remark(let words):
            return words
        case .moved(let directory):
            return Localized.text("Moved to %@", directory)
        case .skill(let name):
            return Localized.text("Using the %@ skill", name)
        }
    }

    /// How much of a command a note names. A note is one quiet line across the transcript, never
    /// the script that ran: opencode hands the whole shell command as the line's description, so
    /// every `cat > script <<'EOF'` the agent ran put its entire body in the transcript when it
    /// finished. The first line is what a person recognises, and a long one is cut with an
    /// ellipsis rather than wrapping the line.
    private static let nameLimit = 80

    private static func oneLine(_ words: String) -> String {
        let first =
            words.split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? words
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > nameLimit else { return trimmed }
        return String(trimmed.prefix(nameLimit - 1)) + "…"
    }

    private static func face(_ subject: TranscriptNote.Subject)
        -> (symbol: String, glyph: String, tone: ActivityTone)
    {
        switch subject {
        case .model: return ("cpu", "◆", .quiet)
        case .agent: return ("person.crop.circle", "◇", .quiet)
        case .resumedAfterRestart: return ("arrow.clockwise.circle", "↻", .attention)
        case .workFinished(_, _, .completed): return ("checkmark.circle", "✓", .quiet)
        case .workFinished(_, _, .cancelled): return ("stop.circle", "■", .quiet)
        case .workFinished(_, _, .failed): return ("xmark.circle", "✗", .attention)
        case .instructions: return ("doc.text", "▤", .quiet)
        case .moved: return ("folder", "▸", .quiet)
        case .skill: return ("wand.and.stars", "✦", .quiet)
        case .remark: return ("info.circle", "·", .quiet)
        }
    }
}
