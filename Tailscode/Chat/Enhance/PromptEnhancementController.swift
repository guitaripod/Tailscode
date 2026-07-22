import Foundation

/// Drives on-device prompt enhancement from live composer input.
///
/// The flow is throttled and pre-emptive: once the draft crosses the length
/// threshold and the user pauses (`debounce`), a refine runs in the background
/// so suggestions are usually already waiting by the time the send button is
/// held. Each new keystroke cancels the in-flight work, the input is clipped
/// before it reaches the model, and a result is cached by its exact input so
/// re-opening the overlay is instant.
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
    private var debounceTask: Task<Void, Never>?
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

    /// Feeds live composer text. Debounces, then pre-generates in the
    /// background. Cheap to call on every keystroke.
    func updateInput(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        latestInput = text
        guard isAvailable else { return }
        debounceTask?.cancel()
        guard Self.isEnhanceable(text) else {
            generationTask?.cancel()
            generatedInput = nil
            if status != .idle, unavailableReason == nil { status = .idle }
            return
        }
        if text == generatedInput, case .ready = status { return }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: PromptEnhancement.debounce)
            guard !Task.isCancelled else { return }
            AppLogger.ui.info("enhance: debounce fired (background) for \(text.count) chars")
            self?.generate(text, visibleLoading: false)
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
        debounceTask?.cancel()
        if text == generatedInput, case .ready = status {
            AppLogger.ui.info("enhance: requestNow — serving cached suggestions")
            return true
        }
        AppLogger.ui.info("enhance: requestNow — generating with visible loading")
        generate(text, visibleLoading: true)
        return true
    }

    func retry() {
        guard Self.isEnhanceable(latestInput) else { return }
        generate(latestInput, visibleLoading: true)
    }

    private func generate(_ text: String, visibleLoading: Bool) {
        generationTask?.cancel()
        if visibleLoading { status = .generating }
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
                    if visibleLoading || self.isShowing { self.status = .failed }
                } else {
                    AppLogger.ui.info("enhance: ready with \(clean.count) cards")
                    self.status = .ready(clean)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let showing = visibleLoading || self.isShowing
                AppLogger.ui.info("enhance: generation error surfaced (overlay showing=\(showing))")
                if showing {
                    self.status = .failed
                } else if status == .generating {
                    self.status = .idle
                }
            }
        }
    }

    /// Whether the overlay is currently on screen — a background failure only
    /// surfaces as `.failed` when someone is actually looking.
    var isShowing = false

    func cancel() {
        debounceTask?.cancel()
        generationTask?.cancel()
    }

    static func isEnhanceable(_ trimmed: String) -> Bool {
        guard trimmed.count >= PromptEnhancement.minCharacters else { return false }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        return words.count >= PromptEnhancement.minWords
    }
}
