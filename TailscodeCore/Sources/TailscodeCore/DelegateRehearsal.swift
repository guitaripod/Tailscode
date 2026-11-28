import CodingAgentKit
import Foundation

/// The first meeting with the dispatcher, which should be the dispatcher working.
///
/// A copy without Pro that pressed Delegate used to meet the price, and a copy with Pro whose
/// machine had no dispatcher met two shell commands; neither had seen a packet climb. The scripted
/// machine already plays the whole feature with no network, so it is the rehearsal: one press sends
/// a practice packet, the run teaches each step in a sentence as it happens, and only then does the
/// road lead on, to Pro for a copy that has not bought it and to the machine's own setup for one
/// that has. Every word and the one decision are here; a client draws a card and two rows.
public enum DelegateRehearsal {
    public static let host = "studio.tailnet-demo.ts.net"
    public static let serverName = "studio"

    /// Where a press on Delegate leads.
    public enum Road: Sendable, Equatable {
        /// The machine's own board.
        case board
        /// The scripted machine first, with the way to the machine's own board beside it.
        case rehearsal
    }

    public static func road(isPro: Bool, sells: Bool, demo: Bool = false) -> Road {
        DelegateProGate.allows(isPro: isPro, sells: sells, demo: demo) ? .board : .rehearsal
    }

    public static func isRehearsal(host: String) -> Bool { host == Self.host }

    public static var title: String { Localized.text("Watch a packet climb") }

    /// The three things a packet is, in the order the practice run shows them.
    public static var points: [String] {
        [
            Localized.text("A packet is a goal, the files it may touch and a command that proves it."),
            Localized.text("The cheapest model that might do it goes first, and it climbs only when the proof fails."),
            Localized.text("What passes waits for you, then lands in your tree unstaged."),
        ]
    }

    public static var practiceTitle: String { Localized.text("Send the practice packet") }

    public static var practiceDetail: String {
        Localized.text("Scripted, on a machine that does not exist. About fifteen seconds.")
    }

    /// The packet the rehearsal sends: a class that starts on the local rung with one rung above
    /// it, so the script fails it once and passes it one rung up, which is the whole lesson.
    public static var practice: DelegateDraft {
        var draft = DelegateDraft(
            packet: DelegatePacket(
                id: "", taskClass: "strings",
                goal: Localized.text("Translate the three new strings in Localizable.xcstrings into Finnish."),
                paths: ["Resources/Localizable.xcstrings"], verify: "scripts/l10n-check.py --strict",
                repo: "/Users/demo/dev/pulse-app"))
        draft.review = true
        return draft
    }

    /// The row that leads from the rehearsal to the person's own machine.
    public static func unlockTitle(serverName: String) -> String {
        Localized.text("Use Delegate on %@", serverName)
    }

    public static var unlockDetail: String { DelegateProGate.requirement }

    /// What the run on screen is teaching right now, or nothing on a machine that is real.
    public static func lesson(_ story: DelegateRunStory, host: String) -> String? {
        guard DelegateDemo.isDemoHost(host) else { return nil }
        switch story.status {
        case .running:
            if story.pendingApproval != nil {
                return Localized.text("A rung you gated waits here. Nothing is spent until you say so.")
            }
            if story.attempts.contains(where: { $0.status != .pass }) {
                return Localized.text("The proof failed, so the next rung is handed the verifier's exact words.")
            }
            return Localized.text("The cheapest rung goes first. A local model costs nothing to try.")
        case .passed:
            switch story.delivery {
            case .pending:
                return Localized.text("It passed its own proof before the frontier was ever asked. Nothing is in the tree until you apply it.")
            case .discarded:
                return Localized.text("Set aside. The tree never saw it, and the patch is still here to read.")
            case .applied, nil:
                return Localized.text("That is the whole loop: a goal, a proof, and the cheapest model that passes it.")
            }
        case .failed:
            return Localized.text("Every rung said no, and each reason is here in the verifier's own words.")
        case .held:
            return Localized.text("You held it before it spent that rung. Nothing ran there.")
        case .cancelled, .error:
            return nil
        }
    }
}
