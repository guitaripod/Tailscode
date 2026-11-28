import Foundation

/// A turn told in short by the model a person runs themselves: what the turn is for, what is
/// happening (or what it came to), and the stages it went through, each ending at a step. The
/// words are the model's; every number a surface shows beside them is counted from the turn and
/// never written. `NeuralGistAsk` asks for one and reads the answer, `NeuralGistDesk` decides when,
/// and `NeuralGistPane` is what a client draws.
public struct NeuralGist: Sendable, Equatable {
    /// A run of steps the model named, one-based and inclusive at both ends.
    public struct Stage: Sendable, Equatable {
        public let says: String
        public let from: Int
        public let to: Int

        public init(says: String, from: Int, to: Int) {
            self.says = says
            self.from = from
            self.to = to
        }

        public var stepCount: Int { to - from + 1 }

        public func contains(_ number: Int) -> Bool { number >= from && number <= to }
    }

    /// What the whole turn is for: "Integrating Antigravity agent support".
    public let title: String
    /// What is happening at the end of what was read, or what a finished turn came to.
    public let now: String
    public let stages: [Stage]
    /// How many steps were read, which is the last stage's end.
    public let stepCount: Int
    /// The turn was still running when this was written, so the last stage is in progress.
    public let running: Bool
    /// The model that wrote it, by the name its server lists it under.
    public let writer: String
    /// The machine it runs on, as a person calls it.
    public let place: String
    public let writtenAt: Date

    public init(
        title: String, now: String, stages: [Stage], stepCount: Int, running: Bool, writer: String,
        place: String, writtenAt: Date
    ) {
        self.title = title
        self.now = now
        self.stages = stages
        self.stepCount = stepCount
        self.running = running
        self.writer = writer
        self.place = place
        self.writtenAt = writtenAt
    }

    /// A model wrote this. An outline is made from the turn's own words and has no writer.
    public var isModelWritten: Bool { !writer.isEmpty }

    public func stage(containing number: Int) -> (index: Int, stage: Stage)? {
        stages.enumerated().first { $0.element.contains(number) }.map { ($0.offset, $0.element) }
    }
}

/// A turn in short as a closed card says it: what it is for and what it came to or is doing.
public struct NeuralGistLine: Sendable, Equatable {
    public let title: String
    public let sentence: String
    /// A model wrote the words, so they wear its mark; an outline's are the turn's own.
    public let isModelWritten: Bool

    public init(title: String, sentence: String, isModelWritten: Bool) {
        self.title = title
        self.sentence = sentence
        self.isModelWritten = isModelWritten
    }

    /// The stages of a turn on one line, in order: what a card says of an outline.
    public static func journey(_ stages: [NeuralGist.Stage]) -> String {
        stages.map(\.says).joined(separator: " \u{00B7} ")
    }

    /// What stands where a speaker's name would: the model's mark and its title, or "In short"
    /// for an outline, whose title is the prompt a card already sits under in the chat.
    public var heading: String {
        guard isModelWritten, !title.isEmpty else { return NeuralGistWords.title }
        return "\(NeuralGistWords.mark) \(title)"
    }
}

/// When a turn is worth telling and how often it may be told again. Pure, so the three clients and
/// the tests agree, and so a slow model on a laptop is never asked faster than it answers.
public enum NeuralGistPolicy {
    /// A turn shorter than this reads at a glance as it is.
    public static let fewestSteps = 10
    /// Stages a telling may have at most.
    public static let mostStages = 7
    /// The shortest wait between two tellings of one running turn.
    public static let shortestWait: TimeInterval = 20
    /// How many times longer than the model took to answer the wait is at least.
    public static let waitPerSecondTaken = 8.0
    /// The steps a running turn must have grown by before it is told again.
    public static let growth = 6
    /// How long a model that did not answer is left alone.
    public static let afterFailure: TimeInterval = 90
    /// How long an answer about whether the model is in memory is believed.
    public static let readinessHolds: TimeInterval = 300

    public static func worthTelling(stepCount: Int) -> Bool { stepCount >= fewestSteps }

    /// The fewest and most stages asked for at a size: a short turn has two or three, a long one
    /// five to seven.
    public static func stageBounds(stepCount: Int) -> ClosedRange<Int> {
        let most = min(mostStages, max(3, stepCount / 40 + 2))
        return max(2, most - 2)...most
    }

    public static func wait(afterTaking seconds: TimeInterval) -> TimeInterval {
        max(shortestWait, seconds * waitPerSecondTaken)
    }

    /// Whether a turn that was told at `told` steps is told again now that it has `stepCount`.
    /// A turn that ended, or one that work coming back woke again, is told at once whatever its
    /// growth, since its sentence changes tense; otherwise nothing is asked while the wait since
    /// the last answer has not passed.
    public static func isDue(
        told: (stepCount: Int, running: Bool)?, stepCount: Int, running: Bool,
        sinceLast: TimeInterval?, lastTook: TimeInterval?, failed: Bool
    ) -> Bool {
        guard worthTelling(stepCount: stepCount) else { return false }
        if failed {
            guard let sinceLast, sinceLast >= afterFailure else { return false }
            return true
        }
        guard let told else { return true }
        let turned = told.running != running
        guard turned || stepCount >= told.stepCount + growth || (!running && stepCount > told.stepCount)
        else { return false }
        if turned { return true }
        guard let sinceLast else { return true }
        return sinceLast >= wait(afterTaking: lastTook ?? 0)
    }
}

/// Whether Megatron is told in short. One switch on this device, on unless the person turned it
/// off; it does nothing until a model is filed, which is the person's own choice.
public enum NeuralGistSetting {
    public static let key = "tailscode.image.gist"
    public static var didChange: Notification.Name { ImageGenStore.didChange }

    public static var isOn: Bool {
        UserDefaults.standard.string(forKey: key) != "off"
    }

    public static func set(_ on: Bool) {
        UserDefaults.standard.set(on ? "on" : "off", forKey: key)
        StoreNotice.post(didChange)
    }
}
