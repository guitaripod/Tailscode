import Foundation

/// The words only the readout says. They live beside the rest of the neural trace's words so the
/// three clients cannot read the same panel differently.
extension NeuralReading {
    public static var nowLabel: String { Localized.text("NOW") }
    public static var whyLabel: String { Localized.text("WHY") }
    public static var soFarLabel: String { Localized.text("So far") }
    public static var changedLabel: String { Localized.text("Changed") }
    public static var failuresLabel: String { Localized.text("Failures") }
    public static var answerLabel: String { Localized.text("Answer") }
    public static var copyLabel: String { Localized.text("Copy") }
    public static var pinnedLabel: String { Localized.text("Pinned") }
    public static var showAllLabel: String { Localized.text("Show all") }
    public static var showMoreLabel: String { Localized.text("Show more") }
    public static var openAgentLabel: String { Localized.text("Open agent") }
    public static var goToApprovalLabel: String { Localized.text("Go to approval") }
    public static var goToQuestionLabel: String { Localized.text("Go to question") }
    public static var neverRetried: String { Localized.text("never retried") }
    public static var retriedWord: String { Localized.text("retried") }

    /// "18 of 29".
    public static func counter(_ number: Int, of total: Int) -> String {
        Localized.text("%1$lld of %2$lld", number, total)
    }

    /// "N more lines" under a block that shows the first few.
    public static func moreLines(_ count: Int) -> String {
        count == 1 ? Localized.text("1 more line") : Localized.text("%lld more lines", count)
    }

    /// "retried at 11".
    public static func retriedAt(_ number: Int) -> String {
        Localized.text("retried at %@", String(number))
    }

    /// "started 21:52:22".
    public static func started(_ clock: String) -> String {
        Localized.text("started %@", clock)
    }

    /// "turn began 21:52:02".
    public static func turnBegan(_ clock: String) -> String {
        Localized.text("turn began %@", clock)
    }

    /// "same file as 3, 5, 22".
    public static func sameFile(_ numbers: [Int]) -> String {
        Localized.text("same file as %@", numbers.map(String.init).joined(separator: ", "))
    }

    /// "same command as 11".
    public static func sameCommand(_ numbers: [Int]) -> String {
        Localized.text("same command as %@", numbers.map(String.init).joined(separator: ", "))
    }

    /// The facts a readout's footer carries: the message's place, said the way a card says it.
    public static func messageFact(of step: NeuralStep, in steps: [NeuralStep]) -> String {
        let siblings = steps.filter { $0.group == step.group }.count
        return siblings > 1
            ? Localized.text("%lld calls in one message", siblings)
            : Localized.text("message %lld", messageNumber(of: step, in: steps))
    }

    /// The sentence at the head of a digest: the count and the time, then what the work did.
    public static func headline(for turn: NeuralTurn, now: Date = Date()) -> String {
        notice(for: turn, now: now)
    }

    /// What a waiting step asks of the person.
    public static func ask(for status: NeuralStatus) -> String {
        status == .waitingAnswer
            ? Localized.text("Waiting for your answer") : Localized.text("Waiting for your approval")
    }

    /// A chip's word: the status in capitals, or RETRIED for a failure a later step cleared.
    public static func chipWord(_ kind: NeuralReadout.ChipKind) -> String {
        switch kind {
        case .done: return statusWord(.ok).uppercased()
        case .failed: return statusWord(.failed).uppercased()
        case .running: return statusWord(.running).uppercased()
        case .waiting: return statusWord(.waitingApproval).uppercased()
        case .stalled: return statusWord(.stalled).uppercased()
        case .stopped: return statusWord(.stopped).uppercased()
        case .retried: return retriedWord.uppercased()
        case .fixed: return verdictFixed.uppercased()
        case .hitError: return verdictHitError.uppercased()
        }
    }
}
