import AppIntents
import Foundation

/// A question asked from outside the app: said to Siri, typed into a Shortcut, or spoken after a
/// Vocal Shortcut. The words are collected before the app opens, so the person says them once and
/// the quick ask is already on its way when Tailscode comes forward. They reach the app in process
/// (`PendingRoute.deliver(question:)`), never as a link anything else on the phone could open.
struct AskQuestionIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask a Question"
    static let description = IntentDescription(
        "Ask your agent a question. Tailscode opens with it already on its way.")
    static let openAppWhenRun = true

    @Parameter(title: "Question", requestValueDialog: IntentDialog("What do you want to ask?"))
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$question)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let words = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            throw $question.needsValueError(IntentDialog("What do you want to ask?"))
        }
        PendingRoute.deliver(question: words)
        return .result()
    }
}
