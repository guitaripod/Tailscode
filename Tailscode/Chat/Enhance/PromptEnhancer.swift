import Foundation
import UIKit
#if canImport(FoundationModels)
import FoundationModels
import MidgarCore
#endif

/// Wraps Apple's on-device Foundation Model to turn a developer's rough draft
/// into a few sharper prompts. All Foundation Models types stay inside this
/// file, behind `#if canImport` + `@available`, so the rest of the app builds
/// and runs unchanged on the iOS 18 baseline (the framework is weak-linked).
@MainActor
final class PromptEnhancer {
    enum Availability: Equatable, Sendable {
        case available
        case unavailable(String)
    }

    /// The model's availability as last read, for the whole app. Reading it asks the system's
    /// model service, and every composer asked on each focus and each keystroke, on the main
    /// thread; the iPad logged 140–330 ms stalls right after a composer took focus. It is read once
    /// when first needed and again off the main thread whenever the app comes forward, which is
    /// when a person can have turned Apple Intelligence on or off.
    private static var known: Availability?
    private static var refreshing = false
    private static var watchingForeground = false
    /// Whether the model has been warmed since the app last came forward. Every conversation used
    /// to build and warm a session of its own on the main thread the first time its composer took
    /// focus; the model is one per device, so it is warmed once, off the main thread.
    private static var warmed = false

    var availability: Availability {
        if let known = Self.known { return known }
        let read = Self.readAvailability()
        Self.known = read
        Self.watchForeground()
        return read
    }

    private static func watchForeground() {
        guard !watchingForeground else { return }
        watchingForeground = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                PromptEnhancer.warmed = false
                PromptEnhancer.refreshAvailability()
            }
        }
    }

    private static func refreshAvailability() {
        guard !refreshing else { return }
        refreshing = true
        Task.detached(priority: .utility) {
            let read = PromptEnhancer.readAvailability()
            await MainActor.run {
                PromptEnhancer.known = read
                PromptEnhancer.refreshing = false
            }
        }
    }

    nonisolated private static func readAvailability() -> Availability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return .unavailable(
                        String(localized: "This device doesn't support Apple Intelligence."))
                case .appleIntelligenceNotEnabled:
                    return .unavailable(
                        String(
                            localized:
                                "Turn on Apple Intelligence in Settings to enhance prompts."))
                case .modelNotReady:
                    return .unavailable(
                        String(
                            localized:
                                "The on-device model is still preparing — try again in a moment."))
                @unknown default:
                    return .unavailable(
                        String(localized: "Prompt enhancement isn't available right now."))
                }
            }
        }
        #endif
        return .unavailable(
            String(localized: "Prompt enhancement needs Apple Intelligence on iOS 26."))
    }

    /// Loads the model into memory once, on the first focus since the app came forward, so the
    /// first real generation doesn't pay the cold-start cost.
    func prewarm() {
        guard !Self.warmed else { return }
        let state = availability
        switch state {
        case .available: MidgarLog.info("enhance: prewarm — model available", category: .ui)
        case .unavailable(let reason): MidgarLog.info(
            "enhance: prewarm — unavailable: \(reason)",
            category: .ui
        )
        }
        guard case .available = state else { return }
        Self.warmed = true
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let instructions = Self.instructions
            Task.detached(priority: .utility) { await ModelWarmth.shared.warm(instructions: instructions) }
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
            MidgarLog.info("enhance: generating for \(clipped.count) chars…", category: .ui)
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
                MidgarLog.info(
                    "enhance: got \(result.count) suggestions in \(ms)ms — labels=\(result.map(\.label))", category: .ui)
                return result
            } catch {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                MidgarLog.error("enhance: generation failed after \(ms)ms: \(error)", category: .ui)
                throw error
            }
        }
        #endif
        throw Unavailable()
    }

    private struct Unavailable: Error {}

    private static let instructions = """
        You are a prompt engineer. Rewrite a developer's rough request into a prompt optimized \
        for an AI coding agent (a large language model with access to the codebase). \
        An optimized prompt: states the task as a direct imperative; names the goal and the \
        desired end state so the agent can verify when it is done; includes every concrete \
        detail the developer gave — file names, symbols, error messages, versions, numbers — \
        verbatim; makes implicit constraints explicit (what must not change, edge cases to \
        handle); and contains no greetings, politeness, filler, or meta-commentary about \
        prompting. Never answer the request, write the code, or invent requirements or details \
        the developer didn't imply. Keep each rewrite tight: a few sentences at most, with no \
        preamble.
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
/// Holds the one warmed session, so the model it loaded stays resident until the system lets it
/// go, without the main thread building or warming it.
@available(iOS 26.0, *)
private actor ModelWarmth {
    static let shared = ModelWarmth()
    private var session: LanguageModelSession?

    func warm(instructions: String) {
        let session = LanguageModelSession(instructions: instructions)
        session.prewarm()
        self.session = session
    }
}

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
