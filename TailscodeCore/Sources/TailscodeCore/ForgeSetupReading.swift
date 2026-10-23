import CodingAgentKit
import Foundation

/// What the setup knows about the address in the field: whether it reads, whether it was asked, and
/// what it said. One value so a client draws one status line and branches on nothing except a
/// failure, which carries its own fix.
public struct ForgeSetupReading: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
        case blank
        case unreadable
        /// A parseable address nobody has asked yet.
        case ready
        case checking
        case listening
        case failed
    }

    public let stage: Stage
    public let title: String
    public let detail: String
    public let tone: ActivityTone
    /// Present exactly when the stage is `failed`, carrying the sentence and the one action that
    /// would fix it — the same value the server flow's failures carry.
    public let diagnosis: ConnectDiagnosis?

    init(
        stage: Stage, title: String, detail: String, tone: ActivityTone,
        diagnosis: ConnectDiagnosis? = nil
    ) {
        self.stage = stage
        self.title = title
        self.detail = detail
        self.tone = tone
        self.diagnosis = diagnosis
    }
}

/// What pressing something in the setup means to the client. Nothing here is a sentence — every
/// word is already on the button — and nothing here is a decision: a client runs the action and
/// hands the answer back.
public enum ForgeSetupAction: Sendable, Equatable {
    case nothing
    /// Ask the port. The client calls `checking()`, awaits `ForgeEndpoint.reach()`, then `reached(_:)`.
    case check(ForgeEndpoint)
    /// File it and use it: `ForgeStore.remember(renderer)`.
    case save(ForgeRenderer)
    /// Sweep the tailnet. The client supplies the peer list its platform can get.
    case scan
    /// The failure's own remedy, wired the same way every other `ConnectDiagnosis` is.
    case fix(ConnectDiagnosis.Fix)
}

public struct ForgeSetupButton: Sendable, Equatable {
    public let title: String
    public let action: ForgeSetupAction
    public let isEnabled: Bool

    init(_ title: String, _ action: ForgeSetupAction, isEnabled: Bool = true) {
        self.title = title
        self.action = action
        self.isEnabled = isEnabled
    }
}

/// The setup surface's own shape: which parts it has and the order a reader meets them in.
///
/// Three clients drew the same five parts in three different orders — the Mac put the machines
/// already used above the scan, the Linux window led with an empty list and buried the form below
/// the fold — so the walk a person takes was a different walk on every desk. The order is therefore
/// a fact of Core's, in the order the decision is actually made: what this surface is and whether
/// this machine can even ask (intro), the way in that is not typing (find), the machines that have
/// already answered (known), the address as typed (address), and what became of it with the one
/// press that settles it (outcome).
public enum ForgeSetupArea: String, Sendable, Equatable, CaseIterable {
    case intro
    case find
    case known
    case address
    case outcome
}
