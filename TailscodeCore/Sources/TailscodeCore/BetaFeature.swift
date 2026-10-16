import Foundation

/// Every feature that is in beta. A feature leaves beta by its case being deleted, so every client
/// loses its mark together; nothing else decides what wears one.
public enum BetaFeature: String, Sendable, CaseIterable {
    case delegate
    case voiceCall

    public var card: BetaCard {
        switch self {
        case .delegate: return Self.delegateCard
        case .voiceCall: return Self.voiceCallCard
        }
    }

    private static var delegateCard: BetaCard {
        BetaCard(
            name: Localized.text("Delegate"),
            symbol: DelegateEntryPoint.symbol,
            glyph: DelegateEntryPoint.glyph,
            title: Localized.text("Delegate is in beta"),
            lead: Localized.text("Hand bounded tasks to your own cheaper models and read the verified result."),
            paragraphs: [
                Localized.text(
                    "Delegate is new and still being shaped. It does real work every day, and what it learns there changes it: the packet, the ladder, the words a run is told in and the tier a class starts at will keep moving between releases until the feature is right."),
                Localized.text(
                    "Beta does not mean pretend. A run is real work on your machine — every attempt is verified before its patch lands, and a patch lands unstaged in your working tree, so read it the way you would read a pull request before you keep it."),
                Localized.text(
                    "When a run, a rung or a sentence here gets something wrong, that is worth reporting: this stage exists to hear it, and the dispatcher's own log on that machine carries every word a report needs."),
            ],
            works: [
                Localized.text("Every attempt is verified before its patch lands"),
                Localized.text("A patch lands unstaged in your working tree; nothing is committed for you"),
            ],
            rough: [
                Localized.text("The packet, the ladder and the tier a class starts at keep moving between releases")
            ],
            changes: [],
            reportName: Localized.text("the dispatcher's own log on that machine"))
    }

    private static var voiceCallCard: BetaCard {
        BetaCard(
            name: VoiceCallEntryPoint.title,
            symbol: VoiceCallEntryPoint.symbol,
            glyph: VoiceCallEntryPoint.glyph,
            title: Localized.text("Calls are in beta"),
            lead: Localized.text("Speak to this chat and it types what you say, as you say it."),
            paragraphs: [
                Localized.text(
                    "A voice model on your own server's GPU listens and writes down your words, and each finished sentence of three words or more goes to the agent in this chat as an ordinary message, exactly as if you had typed it."),
                Localized.text(
                    "It does not talk back, on purpose: the model that listens is not good enough at talking, so it stays quiet, and a chime says when the agent has finished."),
                Localized.text(
                    "What it heard is shown as it arrives and is sometimes wrong, so the agent gets what was heard; nothing leaves your tailnet, because the audio runs from this device to your own machine and nowhere else."),
            ],
            works: [
                Localized.text("Your words are typed into the chat as you speak"),
                Localized.text("What it heard is shown on the strip as it arrives"),
                Localized.text("A chime says when the agent has finished"),
            ],
            rough: [
                Localized.text("It mishears now and then, and the agent gets what it heard"),
                Localized.text("A pause in the middle of a request can split it into two messages"),
                Localized.text("It does not talk back and cannot stop the agent; use the chat for that"),
                Localized.text("English only"),
                Localized.text(
                    "Needs an NVIDIA GPU with about %@ on your server",
                    SetupFormat.megabytes(VoiceRequirements.gpuMemoryMB)),
            ],
            changes: [],
            reportName: Localized.text("voice-bridge on that machine (journalctl --user -u voice-bridge)"))
    }
}

/// One thing that changed in a feature since an older release, in a sentence. Authored only where
/// there is a real change to report.
public struct BetaChange: Sendable, Equatable {
    public let since: SoftwareVersion
    public let line: String

    public init(since: SoftwareVersion, line: String) {
        self.since = since
        self.line = line
    }
}

/// Everything a client says about a feature in beta. A client draws these fields and invents no word.
public struct BetaCard: Sendable, Equatable {
    public let name: String
    public let symbol: String
    public let glyph: String
    public let title: String
    public let lead: String
    public let paragraphs: [String]
    public let works: [String]
    public let rough: [String]
    /// Newest first. Empty when there is nothing real to report, and the card then shows no such section.
    public let changes: [BetaChange]
    /// Where the feature's log lives, in words a person can act on.
    public let reportName: String

    public init(
        name: String, symbol: String, glyph: String, title: String, lead: String,
        paragraphs: [String], works: [String], rough: [String], changes: [BetaChange],
        reportName: String
    ) {
        self.name = name
        self.symbol = symbol
        self.glyph = glyph
        self.title = title
        self.lead = lead
        self.paragraphs = paragraphs
        self.works = works
        self.rough = rough
        self.changes = changes
        self.reportName = reportName
    }

    /// What a screen reader hears where a sighted person sees the capsule.
    public var spoken: String {
        Localized.text("Beta. %@ is new; open this to read what that means.", name)
    }
}
