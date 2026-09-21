import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A rewrite in progress, and then landed: the words the person typed, the paragraph the helper
/// is writing over them, the shape it chose, and where it stands. The card every client draws
/// reads this and nothing else, so the desk and the phone can never say different things about
/// the same rewrite.
public struct ImageGenRewriteDraft: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case writing
        case landed
        case failed(String)
    }

    public let original: String
    public var written: String
    public var aspect: ImageGenAspect?
    public var phase: Phase
    public let helper: ImageGenHelper
    /// What the person asked to change, when this draft is a revision of the one before it.
    public let instruction: String?
    public let startedAt: Date

    public init(
        original: String, written: String = "", aspect: ImageGenAspect? = nil,
        phase: Phase = .writing, helper: ImageGenHelper, instruction: String? = nil,
        startedAt: Date = Date()
    ) {
        self.original = original
        self.written = written
        self.aspect = aspect
        self.phase = phase
        self.helper = helper
        self.instruction = instruction
        self.startedAt = startedAt
    }

    public var isWriting: Bool { phase == .writing }

    public var words: Int { ImageGenBrief.words(in: written) }

    /// Whether there is a paragraph worth taking: landed, and not empty.
    public var isUsable: Bool {
        phase == .landed && !written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The card's first line: who is writing, or who wrote, how much, and in what shape.
    public var headline: String {
        switch phase {
        case .writing:
            return ImageGenRewriteWords.writingLine(helper: helper, words: words)
        case .landed:
            return ImageGenRewriteWords.landedLine(helper: helper, words: words, aspect: aspect)
        case .failed(let reason):
            return reason
        }
    }

    /// What a screen reader is told when the card changes state, which is not every token.
    public var announcement: String {
        switch phase {
        case .writing: return ImageGenRewriteWords.writingLine(helper: helper, words: nil)
        case .landed: return headline
        case .failed(let reason): return reason
        }
    }
}

/// Every word the rewrite card says, in one place.
public enum ImageGenRewriteWords {
    public static var useTitle: String { Localized.text("Use these words") }
    public static var useHint: String {
        Localized.text("Put the paragraph in the box, where it can still be edited")
    }
    public static var keepTitle: String { Localized.text("Keep mine") }
    public static var keepHint: String { Localized.text("Close the rewrite and leave the box as it was") }
    public static var againTitle: String { Localized.text("Write again") }
    public static var againHint: String { Localized.text("Another pass, with the same brief") }
    public static var stopTitle: String { Localized.text("Stop") }
    public static var reviseTitle: String { Localized.text("Revise") }
    public static var instructionPlaceholder: String {
        Localized.text("Tell the helper what to change, then press Return")
    }
    public static var loadedMark: String { Localized.text("in memory") }
    public static var chooseTitle: String { Localized.text("Helper") }
    public static var chooseHint: String {
        Localized.text("Which model rewrites the brief, and on which machine")
    }
    public static var lookAgainTitle: String { Localized.text("Look again") }
    public static var lookAgainHint: String {
        Localized.text("Ask every machine on the way for the models it serves")
    }
    public static var lookingTitle: String { Localized.text("Looking for models…") }
    public static var noneFoundTitle: String { Localized.text("No prompt helper found") }
    public static var noneFoundHint: String {
        Localized.text(
            "Anything OpenAI-shaped will do: Ollama, llama-swap, llama.cpp, LM Studio or vLLM on the machine that paints or on this one")
    }
    /// The studio's own line under the count: which model would write, as a link that opens
    /// the list. Reads as a sentence rather than a control, because it is one.
    public static func withLine(_ name: String) -> String {
        Localized.text("with %@", name)
    }

    public static var offTitle: String { Localized.text("Do not rewrite briefs") }
    public static var onTitle: String { Localized.text("Rewrite briefs again") }

    public static func writingLine(helper: ImageGenHelper, words: Int?) -> String {
        guard let words, words > 0 else {
            return Localized.text("Writing with %@ on %@…", helper.name, helper.displayHost)
        }
        return Localized.text(
            "Writing with %@ · %@ words…", helper.name, "\(words)")
    }

    public static func landedLine(helper: ImageGenHelper, words: Int, aspect: ImageGenAspect?)
        -> String
    {
        var parts = [
            Localized.text("Rewritten by %@", helper.name),
            words == 1 ? Localized.text("1 word") : Localized.text("%@ words", "\(words)"),
        ]
        if let aspect { parts.append(aspect.ratioLabel) }
        return parts.joined(separator: " · ")
    }

    /// The menu row for one model, and its second line.
    public static func modelRow(_ model: ImageGenHelperModel, current: Bool) -> String {
        current ? "✓ \(model.label)" : "   \(model.label)"
    }
}

/// One rewrite from start to landing, run above whichever surface asked for it. The rewriter
/// finds a helper when none is filed, streams the paragraph as it is written, and reports every
/// change of the draft on a background queue — the surface hops itself home. Cancelling stops
/// the stream and reports nothing further.
public final class ImageGenRewriter: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    public init() {}

    /// Starts one rewrite. `filed` is the helper this device knows, if any; with none, or one
    /// switched off, the machines near `endpoint` are surveyed and the best writer is filed for
    /// next time. `onChange` fires with the draft each time it changes, ending on `.landed` or
    /// `.failed`; `onHelper` fires once when a helper was found rather than filed.
    public func start(
        brief: String, context: ImageGenRewriteContext, filed: ImageGenHelper?,
        near endpoint: ImageGenEndpoint?, session: URLSession = .shared,
        onHelper: @escaping @Sendable (ImageGenHelper) -> Void,
        onChange: @escaping @Sendable (ImageGenRewriteDraft?) -> Void
    ) {
        cancel()
        lock.lock()
        cancelled = false
        lock.unlock()
        let original = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        task = Task.detached { [weak self] in
            var using = filed
            if using == nil || using?.enabled == false {
                let servers = await ImageGenHelperFinder.survey(near: endpoint, session: session)
                if let found = ImageGenHelperFinder.preferred(across: servers) {
                    using = found
                    onHelper(found)
                }
            }
            guard let self, !self.isCancelled else { return }
            guard let using, using.enabled else {
                onChange(nil)
                return
            }
            var draft = ImageGenRewriteDraft(
                original: original, helper: using, instruction: context.instruction)
            onChange(draft)
            let enhancer = ImageGenEnhancer(helper: using, session: session)
            let held = Held(draft)
            do {
                let read = try await enhancer.stream(original, context: context) { [weak self] text in
                    guard let self, !self.isCancelled else { return }
                    var current = held.value
                    current.written = text
                    held.value = current
                    onChange(current)
                }
                guard !self.isCancelled else { return }
                draft = held.value
                draft.written = read.prompt
                draft.aspect = read.aspect
                draft.phase = .landed
                onChange(draft)
            } catch let failure as ImageGenEnhancer.Failure {
                guard !self.isCancelled, failure != .cancelled else { return }
                draft = held.value
                draft.phase = .failed(failure.reason)
                onChange(draft)
            } catch {
                guard !self.isCancelled else { return }
                draft = held.value
                draft.phase = .failed(ImageGenEnhancer.Failure.unreachable.reason)
                onChange(draft)
            }
        }
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let running = task
        task = nil
        lock.unlock()
        running?.cancel()
    }

    private final class Held: @unchecked Sendable {
        private let lock = NSLock()
        private var held: ImageGenRewriteDraft
        init(_ value: ImageGenRewriteDraft) { held = value }
        var value: ImageGenRewriteDraft {
            get {
                lock.lock()
                defer { lock.unlock() }
                return held
            }
            set {
                lock.lock()
                held = newValue
                lock.unlock()
            }
        }
    }
}
