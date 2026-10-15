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
            lead: Localized.text(
                "Talk to this chat out loud and hear what the agent is doing while it keeps working."),
            paragraphs: [
                Localized.text(
                    "A call lets you speak a task to the agent already in this chat. A voice model on your own server's GPU listens and speaks; the agent you chose does all of the work, exactly as if you had typed it."),
                Localized.text(
                    "Calls are new and shaped by use. The voice model is small and young, so it sometimes mishears, which is why what it heard is shown on screen as it goes to the agent."),
                Localized.text(
                    "Nothing leaves your tailnet: the audio runs from this device to your own machine and nowhere else."),
            ],
            works: [
                Localized.text("Speak a task and it is sent to the agent as an ordinary message"),
                Localized.text("Talk over the voice at any point and it stops to listen"),
                Localized.text("Ask what the agent is doing and hear a short answer"),
            ],
            rough: [
                Localized.text("English only"),
                Localized.text("Use headphones, or the model hears its own voice and answers itself"),
                Localized.text("You cannot interrupt while it is looking up what the agent is doing"),
                Localized.text("It cannot speak up by itself: a chime says the agent finished, then you ask"),
                Localized.text(
                    "A long call is reset about every minute and a half; the agent keeps its memory, the voice does not"),
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
