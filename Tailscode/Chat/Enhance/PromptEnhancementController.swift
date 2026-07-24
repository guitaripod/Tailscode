import Foundation

/// Drives on-device prompt enhancement.
///
/// Generation is strictly on demand: nothing runs while the user types — the
/// model only spins up when they hold Send (`requestNow`). The input is
/// clipped before it reaches the model, and a result is cached by its exact
/// input so re-opening the overlay for an unchanged draft is instant.
@MainActor
final class PromptEnhancementController {
    enum Status: Equatable {
        case idle
        case generating
        case ready([EnhancedPrompt])
        case failed
        case unavailable(String)
    }

    private let enhancer = PromptEnhancer()
    private var generationTask: Task<Void, Never>?

    /// The input backing the cached `.ready` result, if any.
    private var generatedInput: String?
    /// The most recent trimmed draft the controller has seen.
    private(set) var latestInput = ""

    private(set) var status: Status = .idle {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    var onStatusChange: ((Status) -> Void)?

    var isEnabled: Bool { AppPreferences.promptEnhancement }

    var isAvailable: Bool {
        guard isEnabled else { return false }
        if case .available = enhancer.availability { return true }
        return false
    }

    private var unavailableReason: String? {
        if case .unavailable(let reason) = enhancer.availability { return reason }
        return nil
    }

    /// True only when the cached suggestions match the current draft — used to
    /// light the composer's "hold to enhance" hint without lying about staleness.
    var hasFreshSuggestions: Bool {
        if case .ready = status { return generatedInput == latestInput }
        return false
    }

    /// Warms the model into memory the moment the composer gains focus, so the
    /// first real generation doesn't pay the cold-start cost.
    func prewarm() {
        guard isAvailable else { return }
        enhancer.prewarm()
    }

    /// Feeds live composer text. Never generates — it only tracks the draft
    /// and drops a cached result once the draft stops matching it. Cheap to
    /// call on every keystroke.
    func updateInput(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        latestInput = text
        guard isAvailable else { return }
        guard Self.isEnhanceable(text) else {
            generationTask?.cancel()
            generatedInput = nil
            if status != .idle, unavailableReason == nil { status = .idle }
            return
        }
    }

    /// Called when the user opens the overlay: guarantees suggestions for the
    /// exact current draft, showing a visible loading state if we have to wait.
    /// Returns `false` when the draft is too short to enhance.
    @discardableResult
    func requestNow(for raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        latestInput = text
        if let reason = unavailableReason {
            AppLogger.ui.info("enhance: requestNow — unavailable")
            status = .unavailable(reason)
            return true
        }
        guard Self.isEnhanceable(text) else {
            AppLogger.ui.info("enhance: requestNow — draft too short (\(text.count) chars)")
            status = .unavailable("Add a bit more detail, then hold Send to refine it.")
            return true
        }
        if text == generatedInput, case .ready = status {
            AppLogger.ui.info("enhance: requestNow — serving cached suggestions")
            return true
        }
        AppLogger.ui.info("enhance: requestNow — generating")
        generate(text)
        return true
    }

    func retry() {
        guard Self.isEnhanceable(latestInput) else { return }
        generate(latestInput)
    }

    private func generate(_ text: String) {
        generationTask?.cancel()
        status = .generating
        generationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let prompts = try await self.enhancer.enhance(text)
                guard !Task.isCancelled else { return }
                let clean = prompts.filter {
                    !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                self.generatedInput = clean.isEmpty ? nil : text
                if clean.isEmpty {
                    AppLogger.ui.info("enhance: no usable suggestions returned")
                    self.status = .failed
                } else {
                    AppLogger.ui.info("enhance: ready with \(clean.count) cards")
                    self.status = .ready(clean)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.ui.info("enhance: generation error surfaced")
                self.status = .failed
            }
        }
    }

    func cancel() {
        generationTask?.cancel()
    }

    static func isEnhanceable(_ trimmed: String) -> Bool {
        guard trimmed.count >= PromptEnhancement.minCharacters else { return false }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        return words.count >= PromptEnhancement.minWords
    }
}
