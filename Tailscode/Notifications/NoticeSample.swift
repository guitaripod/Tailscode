import Foundation

#if !NOTICE_EXTENSION
    import TailscodeCore
#endif

/// A notice of each kind, made up, for the Settings button that shows what they look like. The
/// numbers are invented and the passages are the sort of thing a server says.
enum NoticeSample: String, CaseIterable, Sendable {
    case finished, failed, approval, question, choices

    var menuTitle: String {
        switch self {
        case .finished: return NoticeWords.sentence(Localized.text("finished"))
        case .failed: return NoticeWords.sentence(Localized.text("failed"))
        case .approval: return NoticeWords.sentence(Localized.text("needs approval"))
        case .question: return NoticeWords.sentence(Localized.text("has a question"))
        case .choices:
            return NoticeWords.sentence(Localized.text("has a question")) + ": Postgres / SQLite"
        }
    }

    var title: String {
        switch self {
        case .finished: return "Enrich the notifications"
        case .failed: return "Write the release notes"
        case .approval: return "Clean the build folder"
        case .question, .choices: return "Pick a database"
        }
    }

    var wire: NoticeWire {
        switch self {
        case .finished:
            return NoticeWire(
                kind: .done, seconds: 505, tools: 25, added: 5, removed: 2,
                text: String(
                    localized: "Notifications are working. This is what a finished turn looks like."),
                server: "arch", agent: "claudeCode",
                glyph: NeuralGlyphWire(
                    zones: [2, 3, 2, 18, 2, 2], eye: NeuralTone.identity.rawValue, hue: "#d97757",
                    hueLight: "#d97757", reads: 3))
        case .failed:
            return NoticeWire(
                kind: .failed, seconds: 241, tools: 3,
                text: "The provider returned an error: overloaded, try again shortly",
                prompt: "Write the release notes from the commit log since the last release",
                server: "arch", agent: "claudeCode",
                glyph: NeuralGlyphWire(
                    zones: [1, 2, 0, 4, 0, 1], failed: 1 << NeuralZone.shell.rawValue,
                    active: NeuralZone.shell.rawValue, eye: NeuralTone.danger.rawValue))
        case .approval:
            return NoticeWire(
                kind: .approval, text: "rm -rf build/ && swift build -c release", subject: "Bash",
                server: "arch", agent: "opencode",
                glyph: NeuralGlyphWire(
                    zones: [1, 3, 1, 5, 0, 0], active: NeuralZone.shell.rawValue,
                    eye: NeuralTone.attention.rawValue))
        case .question:
            return NoticeWire(
                kind: .question, text: "Which database should the notes live in?", free: true,
                server: "arch", agent: "claudeCode",
                glyph: NeuralGlyphWire(
                    zones: [2, 3, 1, 2, 0, 0], active: NeuralZone.think.rawValue,
                    eye: NeuralTone.attention.rawValue))
        case .choices:
            return NoticeWire(
                kind: .question, text: "Which database should the notes live in?",
                options: [
                    NoticeWire.Option(label: "Postgres", detail: "A shared server, backups, concurrent writers."),
                    NoticeWire.Option(label: "SQLite", detail: "One file, no service to run, fine below ten users."),
                ], multiple: false, free: true, server: "arch", agent: "claudeCode",
                glyph: NeuralGlyphWire(
                    zones: [2, 3, 1, 2, 0, 0], active: NeuralZone.think.rawValue,
                    eye: NeuralTone.attention.rawValue))
        }
    }
}
