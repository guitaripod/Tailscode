import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Wraps Apple's on-device Foundation Model to turn a developer's rough draft
/// into a few sharper prompts. All Foundation Models types stay inside this
/// file, behind `#if canImport` + `@available`, so the rest of the app builds
/// and runs unchanged on the iOS 18 baseline (the framework is weak-linked).
@MainActor
final class PromptEnhancer {
    enum Availability: Equatable {
        case available
        case unavailable(String)
    }

    private var warmSession: AnyObject?
    private var didPrewarm = false

    var availability: Availability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return .unavailable("This device doesn't support Apple Intelligence.")
                case .appleIntelligenceNotEnabled:
                    return .unavailable("Turn on Apple Intelligence in Settings to enhance prompts.")
                case .modelNotReady:
                    return .unavailable("The on-device model is still preparing — try again in a moment.")
                @unknown default:
                    return .unavailable("Prompt enhancement isn't available right now.")
                }
            }
        }
        #endif
        return .unavailable("Prompt enhancement needs Apple Intelligence on iOS 26.")
    }

    /// Loads the model into memory once, on first focus, so the first real
    /// generation doesn't pay the cold-start cost.
    func prewarm() {
        switch availability {
        case .available: AppLogger.ui.info("enhance: prewarm — model available")
        case .unavailable(let reason): AppLogger.ui.info("enhance: prewarm — unavailable: \(reason)")
        }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard !didPrewarm, case .available = availability else { return }
            didPrewarm = true
            let session = LanguageModelSession(instructions: Self.instructions)
            session.prewarm()
            warmSession = session
        }
        #endif
    }

    /// Produces `PromptEnhancement.suggestionCount` distinct rewrites via guided
    /// generation. A fresh session per call keeps each refine independent (no
    /// transcript accumulation, no cross-talk between drafts).
    func enhance(_ input: String) async throws -> [EnhancedPrompt] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let clipped = String(input.prefix(PromptEnhancement.maxInputCharacters))
            AppLogger.ui.info("enhance: generating for \(clipped.count) chars…")
            let started = Date()
            let session = LanguageModelSession(instructions: Self.instructions)
            let options = GenerationOptions(temperature: 0.7, maximumResponseTokens: 700)
            do {
                let response = try await session.respond(
                    to: Self.userPrompt(for: clipped),
                    generating: EnhancementSet.self,
                    options: options)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let result = response.content.suggestions.enumerated().map { index, item in
                    EnhancedPrompt(
                        id: index,
                        label: item.label.trimmingCharacters(in: .whitespacesAndNewlines),
                        text: item.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                AppLogger.ui.info(
                    "enhance: got \(result.count) suggestions in \(ms)ms — labels=\(result.map(\.label))")
                return result
            } catch {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                AppLogger.ui.error("enhance: generation failed after \(ms)ms: \(error)")
                throw error
            }
        }
        #endif
        throw Unavailable()
    }

    private struct Unavailable: Error {}

    private static let instructions = """
        You are a prompt engineer helping a developer talk to an AI coding agent. \
        Rewrite the developer's rough request into a clearer, more effective prompt. \
        Keep their intent and every concrete detail they gave — file names, symbols, error \
        messages, versions, and numbers. Make the request specific, unambiguous, and state the \
        outcome they want. Never answer the request, write the code, or invent requirements they \
        didn't imply. Keep each rewrite tight: a few sentences at most, with no preamble.
        """

    private static func userPrompt(for draft: String) -> String {
        """
        Rewrite the following coding request in three distinctly different ways, and give each a \
        short label naming its angle (for example "More specific", "Adds constraints", or "Step by \
        step"). Preserve the meaning — just make each one a stronger prompt for a coding agent.

        Request:
        \(draft)
        """
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
private struct EnhancementSet {
    @Guide(description: "Exactly three rewrites of the request, each taking a clearly different angle", .count(3))
    var suggestions: [EnhancementItem]
}

@available(iOS 26.0, *)
@Generable
private struct EnhancementItem {
    @Guide(description: "A 2 to 4 word label naming this rewrite's angle, e.g. 'More specific' or 'Adds constraints'")
    var label: String

    @Guide(description: "The rewritten prompt: clearer and more specific, preserving the developer's intent and every concrete detail")
    var prompt: String
}
#endif
