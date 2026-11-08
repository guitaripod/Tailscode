import Foundation

/// How a take was opened. A tap leaves the microphone open until it is tapped again; a press held
/// past `DictationPress.holdThreshold` keeps it open only while held.
public enum DictationMode: String, Sendable, Equatable {
    case handsFree
    case held
}

/// Where a held take will go when it is released: kept in the box, thrown away, or sent.
public enum DictationArm: Sendable, Equatable {
    case none
    case cancel
    case send
}

/// Why dictation cannot listen, or why a take ended early. Each one has its own words and, where
/// there is one, its own fix: a reason is never a raw error.
public enum DictationProblem: Sendable, Equatable {
    case microphoneDenied
    case noMicrophone
    case languageUnsupported(String)
    case engine(String)
    case taken
    case timeUp

    /// Whether the words heard before it happened are kept. Only a microphone that never opened has
    /// none to keep.
    public var keepsWords: Bool {
        switch self {
        case .microphoneDenied, .noMicrophone, .languageUnsupported: return false
        case .engine, .taken, .timeUp: return true
        }
    }

    /// Whether this one blocks the next take until something outside the app changes.
    public var blocks: Bool {
        switch self {
        case .microphoneDenied, .noMicrophone, .languageUnsupported: return true
        case .engine, .taken, .timeUp: return false
        }
    }
}

/// Whether an engine can listen in a language right now, and what stands in the way if not.
/// `needsDownload` carries the size when the engine knows it; Apple's asset inventory does not say.
public enum DictationReadiness: Sendable, Equatable {
    case ready
    case needsDownload(bytes: Int64?)
    case downloading(Double?)
    case unavailable(DictationProblem)
}

/// What a take is doing. A take that has ended is `idle` again and says how it ended in
/// `DictationSnapshot.ended`.
public enum DictationPhase: Sendable, Equatable {
    case idle
    case waking
    case listening
    case settling
}

/// How the last take ended, for the hint line and the screen reader.
public enum DictationEnd: Sendable, Equatable {
    case kept(words: Int)
    case sent(words: Int)
    case discarded
    case nothingHeard
    case problem(DictationProblem)
}

/// One thing the engine heard. A volatile result replaces the tail still being heard; a final one
/// is settled, appended after what was settled before it, and clears the tail.
public enum DictationHeard: Sendable, Equatable {
    case volatile(String)
    case final(String)
}

/// Everything a client draws of a take at one instant. The stream of these is latest-wins, so a
/// slow screen skips frames and never falls behind.
public struct DictationSnapshot: Sendable, Equatable {
    public var phase: DictationPhase
    public var mode: DictationMode
    public var arm: DictationArm
    public var settled: String
    public var heard: String
    public var startedAt: TimeInterval?
    public var nearingLimit: Bool
    public var ended: DictationEnd?
    public var take: Int

    public init(
        phase: DictationPhase = .idle, mode: DictationMode = .handsFree, arm: DictationArm = .none,
        settled: String = "", heard: String = "", startedAt: TimeInterval? = nil,
        nearingLimit: Bool = false, ended: DictationEnd? = nil, take: Int = 0
    ) {
        self.phase = phase
        self.mode = mode
        self.arm = arm
        self.settled = settled
        self.heard = heard
        self.startedAt = startedAt
        self.nearingLimit = nearingLimit
        self.ended = ended
        self.take = take
    }

    public static let idle = DictationSnapshot()

    /// The microphone is open, or about to be: the edge is lit and the control is the capsule.
    public var isOpen: Bool { phase == .waking || phase == .listening }

    /// Words this take has produced so far, settled and still heard, as one string.
    public var words: String { DictationText.join(settled, heard) }

    public var wordCount: Int { DictationText.wordCount(words) }
}

/// The small text rules every engine and client share.
public enum DictationText {
    /// Two runs of dictated words as one, with a single space between them where neither side
    /// already has one and the second does not open with punctuation that hugs the word before.
    public static func join(_ first: String, _ second: String) -> String {
        guard !first.isEmpty else { return second }
        guard !second.isEmpty else { return first }
        guard let last = first.last, let next = second.first else { return first + second }
        if last.isWhitespace || next.isWhitespace || hugsPrevious(next) { return first + second }
        return first + " " + second
    }

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Punctuation that belongs to the word before it, so no space is put in front of it.
    static func hugsPrevious(_ character: Character) -> Bool {
        ".,;:!?)]}…'’\"”%".contains(character)
    }

    /// Characters after which the next word needs no space: an opening bracket or quote, a slash or
    /// an at sign that starts a path or a mention.
    static func opensNext(_ character: Character) -> Bool {
        "([{\"“'‘/@#`$".contains(character)
    }

    /// Whether text ending here is at the start of a sentence: nothing before it, or a sentence end
    /// or a line break before the whitespace that leads to it.
    static func isSentenceStart(after text: String) -> Bool {
        for character in text.reversed() {
            if character.isNewline { return true }
            if character.isWhitespace { continue }
            return ".!?".contains(character)
        }
        return true
    }
}
